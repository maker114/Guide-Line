import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/nav_icon_motion.dart';

/// 选中指示器（胶囊 + 惯性）的几何：这是纯逻辑，先用函数钉住。
void main() {
  group('navIndicatorGeometry（几何）', () {
    const double nominal = 80;
    const double barWidth = 320;

    ({double left, double width}) at(
      double t, {
      double from = 0,
      double to = 80,
    }) =>
        navIndicatorGeometry(
          t: t,
          fromLeft: from,
          toLeft: to,
          nominalWidth: nominal,
        );

    test('进度 0 / 1 停在起点与终点，宽度正好一格', () {
      final start = at(0);
      expect(start.left, closeTo(0, 1e-9));
      expect(start.width, closeTo(nominal, 1e-9));

      final end = at(1);
      expect(end.left, closeTo(80, 1e-9));
      expect(end.width, closeTo(nominal, 1e-9));
    });

    test('最左 / 最右那格与外部胶囊的两端圆弧重合', () {
      // 最左：left = 0（与胶囊左内缘齐平）；最右：right = 栏宽
      expect(at(1, to: 0).left, closeTo(0, 1e-9));
      expect(at(1, from: 240, to: 240).left + at(1, from: 240, to: 240).width,
          closeTo(barWidth, 1e-9));
    });

    test('途中被拉长：起步与落位都不鼓，前半程最鼓、后半程提前收回', () {
      expect(at(0.02).width, lessThan(nominal + 2), reason: '起步不该突然弹宽');
      expect(at(0.98).width, lessThan(nominal + 1), reason: '落位前应当基本收回');

      var peak = 0.0;
      for (var step = 0; step <= 20; step += 1) {
        final width = at(step / 20).width;
        expect(width, greaterThanOrEqualTo(nominal - 1e-9));
        expect(width, lessThanOrEqualTo(nominal + navStretchMax + 1e-9),
            reason: '拉伸超过上限');
        if (width > peak) peak = width;
      }
      expect(peak, greaterThan(nominal + 8), reason: '该拉长的时候要看得出来');

      // 「质量小一点」（实机反馈"太粘滞"）：峰值靠前，后半程就收回大半，
      // 而不是一路鼓到最后几帧才追平
      expect(at(0.4).width, greaterThan(at(0.6).width), reason: '峰值应当在前半程');
      expect(at(0.9).width - nominal, lessThan(navStretchMax * 0.25),
          reason: '后段应当已经收回大半（收得不比原值慢）');
    });

    test('拖拽的拉伸上限调大一档：12 → 18（×1.5），包络形状不变', () {
      // 批 C 第 ② 项：12 那一版被"太粘滞"压过头了，拖动时几乎看不出被拉长。
      // 只把幅度放回一档，包络（峰值位置、后半程提前收）不动。
      expect(navStretchMaxReduced, 12, reason: '关闭动画时用的是这个原值');
      expect(navStretchMax, closeTo(navStretchMaxReduced * 1.5, 1e-9));

      double peakWith(double max) {
        var peak = 0.0;
        for (var step = 0; step <= 1000; step += 1) {
          final width = navIndicatorGeometry(
            t: step / 1000,
            fromLeft: 0,
            toLeft: 80,
            nominalWidth: nominal,
            stretchMax: max,
          ).width;
          peak = math.max(peak, width - nominal);
        }
        return peak;
      }

      // 包络 sin(πt)·(1 − 0.4t) 的峰值在 t ≈ 0.452，约 0.81 × 上限
      final peak = peakWith(navStretchMax);
      expect(peak, greaterThan(navStretchMax * 0.80));
      expect(peak, lessThan(navStretchMax * 0.82));
      expect(peakWith(navStretchMaxReduced), closeTo(peak / 1.5, 0.05),
          reason: '退化那一档就是原值，比例正好是 1 : 1.5');
    });

    test('点按的过冲有界（行程的 3%~5%），而且照样正好落在整数格上', () {
      // 只取**不贴两端**的跳法：贴边时过冲会被导航条夹住（下一条用例管那个）
      const jumps = <List<double>>[
        <double>[0, 80],
        <double>[80, 160],
        <double>[160, 80],
        <double>[240, 160],
      ];
      for (final jump in jumps) {
        final rightward = jump[1] > jump[0];
        final travel = (jump[1] - jump[0]).abs();
        final targetEdge = rightward ? jump[1] + nominal : jump[1];

        var overshoot = 0.0;
        for (var step = 0; step <= 400; step += 1) {
          final geometry = navIndicatorGeometry(
            t: step / 400,
            fromLeft: jump[0],
            toLeft: jump[1],
            nominalWidth: nominal,
            tapSettle: true,
          );
          final edge = rightward
              ? geometry.left + geometry.width
              : geometry.left;
          final beyond = rightward ? edge - targetEdge : targetEdge - edge;
          if (beyond > overshoot) overshoot = beyond;
        }
        final ratio = overshoot / travel;
        expect(ratio, greaterThan(0.03),
            reason: '$jump 的过冲太小，点按就还是"平"的');
        expect(ratio, lessThanOrEqualTo(0.05),
            reason: '$jump 的过冲超过行程的 5%，看着像没对准');

        // 结束值必须与常规曲线**一模一样**：页面翻页读的是同一个连续页位置，
        // 只要落点一致，过冲就不会留下错位
        final settled = navIndicatorGeometry(
          t: 1,
          fromLeft: jump[0],
          toLeft: jump[1],
          nominalWidth: nominal,
          tapSettle: true,
        );
        final plain = at(1, from: jump[0], to: jump[1]);
        expect(settled.left, closeTo(jump[1], 1e-9), reason: '过冲后要正好停在目标格');
        expect(settled.width, closeTo(nominal, 1e-9), reason: '落位后收回一格宽');
        expect(settled.left, closeTo(plain.left, 1e-9));
        expect(settled.width, closeTo(plain.width, 1e-9));
      }
    });

    test('过冲不许把胶囊顶出导航条：贴两端时被夹在栏内', () {
      const jumps = <List<double>>[
        <double>[0, 240], // 跳到最右那一格：右边界本来就会顶到栏尾
        <double>[240, 0], // 跳到最左那一格
        <double>[80, 0],
        <double>[160, 240],
        <double>[0, 80],
      ];
      for (final jump in jumps) {
        for (var step = 0; step <= 400; step += 1) {
          final geometry = navIndicatorGeometry(
            t: step / 400,
            fromLeft: jump[0],
            toLeft: jump[1],
            nominalWidth: nominal,
            tapSettle: true,
          );
          expect(geometry.left, greaterThanOrEqualTo(-1e-9),
              reason: '$jump 在 t=${step / 400} 越出左边界');
          expect(geometry.left + geometry.width,
              lessThanOrEqualTo(barWidth + 1e-9),
              reason: '$jump 在 t=${step / 400} 越出右边界（会从外胶囊头顶出来）');
        }
      }
    });

    test('鼓起时不会越出导航条（含跨三格、两端起跳）', () {
      const jumps = <List<double>>[
        <double>[0, 240], // 向右跳三格
        <double>[240, 0], // 向左跳三格
        <double>[0, 80],
        <double>[80, 0],
        <double>[160, 240], // 贴着右端收尾
      ];
      for (final jump in jumps) {
        for (var step = 0; step <= 40; step += 1) {
          final t = step / 40;
          final geometry = at(t, from: jump[0], to: jump[1]);
          expect(geometry.left, greaterThanOrEqualTo(-1e-9), reason: 't=$t 越出左边界');
          expect(geometry.left + geometry.width, lessThanOrEqualTo(barWidth + 1e-9),
              reason: 't=$t 越出右边界');
        }
      }
    });

    test('往右移时右边界只朝右走，到位就停住、不越过也不回退', () {
      // 用户反馈的原话：往右移动时右边界到位之后还会略微往左挪一下。
      // 那是"把中心放在缓动位置上、宽度对称地鼓"造成的回弹；现在拉长全部长在
      // 尾随边上，前导边（右边）就该是单调到位。
      //
      // 这条**只管拖拽**（`tapSettle` 默认关）：点按那一下是隔空的，
      // 故意让它过冲一点点再吸回来（见"点按的过冲有界"那条用例）。
      const jumps = <List<double>>[
        <double>[0, 80],
        <double>[80, 160],
        <double>[0, 240], // 跨三格
        <double>[80, 240],
      ];
      for (final jump in jumps) {
        final targetRight = jump[1] + nominal;
        double? previous;
        for (var step = 0; step <= 60; step += 1) {
          final geometry = at(step / 60, from: jump[0], to: jump[1]);
          final right = geometry.left + geometry.width;
          expect(right, lessThanOrEqualTo(targetRight + 1e-9),
              reason: 't=${step / 60} 右边界越过了目标格');
          if (previous != null) {
            expect(right, greaterThanOrEqualTo(previous - 1e-9),
                reason: 't=${step / 60} 右边界往左退了');
          }
          previous = right;
        }
        expect(previous, closeTo(targetRight, 1e-9), reason: '最后要正好停在目标格边界');
      }
    });

    test('往左移时左边界同样只朝左走，到位就停住', () {
      const jumps = <List<double>>[
        <double>[80, 0],
        <double>[240, 0],
        <double>[240, 160],
      ];
      for (final jump in jumps) {
        double? previous;
        for (var step = 0; step <= 60; step += 1) {
          final left = at(step / 60, from: jump[0], to: jump[1]).left;
          expect(left, greaterThanOrEqualTo(jump[1] - 1e-9),
              reason: 't=${step / 60} 左边界越过了目标格');
          if (previous != null) {
            expect(left, lessThanOrEqualTo(previous + 1e-9),
                reason: 't=${step / 60} 左边界往右退了');
          }
          previous = left;
        }
        expect(previous, closeTo(jump[1], 1e-9));
      }
    });

    test('尾随边只朝目标方向走，不会倒着退回去', () {
      const jumps = <List<double>>[
        <double>[0, 80],
        <double>[0, 240],
        <double>[80, 0],
        <double>[240, 0],
      ];
      for (final jump in jumps) {
        final rightward = jump[1] > jump[0];
        double? previous;
        for (var step = 0; step <= 40; step += 1) {
          final geometry = at(step / 40, from: jump[0], to: jump[1]);
          // 尾随边 = 运动方向**后面**那条边
          final trailing = rightward ? geometry.left : geometry.left + geometry.width;
          if (previous != null) {
            expect(
              rightward ? trailing : -trailing,
              greaterThanOrEqualTo((rightward ? previous : -previous) - 1e-9),
              reason: 't=${step / 40} 尾随边倒退',
            );
          }
          previous = trailing;
        }
      }
    });
  });

  group('AppBottomNav（实机那一层）', () {
    /// 一个能改页位置的宿主：真实用法里这个数由 `PageController` 每帧喂进来，
    /// 这里直接改，等价于"手指把页面拖到某个位置"。
    final hostKey = GlobalKey<_HostState>();

    Future<void> pumpNav(WidgetTester tester, {bool disableAnimations = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: _Host(key: hostKey, disableAnimations: disableAnimations),
          ),
        ),
      );
    }

    testWidgets('停稳时胶囊与格子同宽，最左 / 最右都贴住胶囊的弧', (tester) async {
      await pumpNav(tester);

      Rect bar() => tester.getRect(find.byType(AppBottomNav));
      Rect pill() => tester.getRect(find.byKey(navIndicatorKey));

      // 起点是第 0 格：左端与外部胶囊左内缘齐平
      expect(pill().left - bar().left, closeTo(0, 0.01));
      expect(pill().width, closeTo(bar().width / 4, 0.01));
      expect(pill().height, closeTo(48, 0.01));

      // 到最后一格：右端与外部胶囊右内缘齐平
      hostKey.currentState!.dragTo(3);
      await tester.pumpAndSettle();
      expect(bar().right - pill().right, closeTo(0, 0.01));
      expect(pill().width, closeTo(bar().width / 4, 0.01));
    });

    testWidgets('拖到一半时胶囊跟着走、被拉长，落位后收回原宽', (tester) async {
      await pumpNav(tester);

      final barWidth = tester.getRect(find.byType(AppBottomNav)).width;
      final nominal = barWidth / 4;

      // 模拟"手指把页面从第 0 页拖到第 1 页的一半"，逐帧量
      double? previousRight;
      var stretched = false;
      for (final page in <double>[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0]) {
        hostKey.currentState!.dragTo(page);
        await tester.pump();
        final rect = tester.getRect(find.byKey(navIndicatorKey));
        expect(rect.right, lessThanOrEqualTo(nominal * 2 + 0.01), reason: '右边界越过了目标');
        if (previousRight != null) {
          expect(rect.right, greaterThanOrEqualTo(previousRight - 0.01),
              reason: 'page=$page 右边界往左退了');
        }
        previousRight = rect.right;
        if (rect.width > nominal + 0.5) stretched = true;
      }
      expect(stretched, isTrue, reason: '拖拽途中应当被拉长');

      final settled = tester.getRect(find.byKey(navIndicatorKey));
      expect(settled.width, closeTo(nominal, 0.01), reason: '落位后要收回原宽');
      expect(settled.left, closeTo(nominal, 0.01));
    });

    testWidgets('超出范围的页位置会被夹住，不会把胶囊画到栏外', (tester) async {
      await pumpNav(tester);

      final bar = tester.getRect(find.byType(AppBottomNav));
      for (final page in <double>[-1.0, 3.0, 5.0]) {
        hostKey.currentState!.dragTo(page);
        await tester.pump();
        final pill = tester.getRect(find.byKey(navIndicatorKey));
        expect(pill.left, greaterThanOrEqualTo(bar.left - 0.01));
        expect(pill.right, lessThanOrEqualTo(bar.right + 0.01));
      }
    });

    testWidgets('关闭动画时退化：拖拽还是被拉长，但幅度回到原上限 12', (tester) async {
      await pumpNav(tester, disableAnimations: true);

      final barWidth = tester.getRect(find.byType(AppBottomNav)).width;
      final nominal = barWidth / 4;

      var peak = 0.0;
      for (final page in <double>[0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.8, 1.0]) {
        hostKey.currentState!.dragTo(page);
        await tester.pump();
        final width = tester.getRect(find.byKey(navIndicatorKey)).width;
        peak = math.max(peak, width - nominal);
      }
      expect(peak, greaterThan(3), reason: '退化不是"完全不拉伸"，只是回到原来那一档');
      expect(peak, lessThanOrEqualTo(navStretchMaxReduced + 0.01));
      expect(peak, lessThan(navStretchMax * 0.9),
          reason: '明显小于正常那一档，否则等于没退化');
    });

    /// 这一项此刻**动起来了没有**：不关心它用的是哪种手势 ——
    /// 子树里有非恒等的 `Transform`、灯泡那圈光线正在画、或者折线还没走完，
    /// 都算"动起来了"。
    bool iconIsMoving(WidgetTester tester, String label) {
      final scope = find.byKey(navIconKey(label));
      final transforms = tester.widgetList<Transform>(
        find.descendant(of: scope, matching: find.byType(Transform)),
      );
      for (final transform in transforms) {
        final storage = transform.transform.storage;
        for (var i = 0; i < 16; i += 1) {
          final expected = (i % 5 == 0) ? 1.0 : 0.0;
          if ((storage[i] - expected).abs() > 1e-6) return true;
        }
      }
      final paints = tester.widgetList<CustomPaint>(
        find.descendant(of: scope, matching: find.byType(CustomPaint)),
      );
      for (final paint in paints) {
        final painter = paint.painter;
        if (painter is NavBulbRays && painter.progress > 0.05) return true;
      }
      // 折线静止时是"画满"（reveal = 1），所以小于 1 就是还在走
      final clips = tester.widgetList<ClipRect>(
        find.descendant(of: scope, matching: find.byType(ClipRect)),
      );
      for (final clip in clips) {
        final clipper = clip.clipper;
        if (clipper is NavIconRevealClipper && clipper.reveal < 0.99) return true;
      }
      return false;
    }

    /// 点一下之后在动画里的若干时刻采样 —— 只要有一个时刻在动就算动过。
    ///
    /// 不能只挑一个时刻看：四种手势相位不同（"摆两下"在正中间恰好回到原位）。
    Future<bool> tapAndWatch(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      await tester.pump();
      var moved = false;
      for (var step = 0; step < 5; step += 1) {
        await tester.pump(const Duration(milliseconds: 60));
        if (iconIsMoving(tester, label)) moved = true;
      }
      await tester.pumpAndSettle();
      return moved;
    }

    testWidgets('变成选中时才播：四种手势都会动，播完回到静止', (tester) async {
      await pumpNav(tester);

      const order = <String>['灵感', '项目', '事件', '更多'];
      for (final label in order) {
        expect(iconIsMoving(tester, label), isFalse, reason: '$label 静止时不该在动');
      }

      for (var i = 0; i < order.length; i += 1) {
        // 先离开这一项 —— 现在是"变成选中才播"，已经选中的那一项不会重播
        hostKey.currentState!.dragTo(((i + 1) % order.length).toDouble());
        await tester.pumpAndSettle();

        expect(
          await tapAndWatch(tester, order[i]),
          isTrue,
          reason: '${order[i]} 选中时应当动起来',
        );
        expect(iconIsMoving(tester, order[i]), isFalse,
            reason: '${order[i]} 播完要回到静止');
      }
    });

    testWidgets('从选中退出去的那一项**不再**播一次', (tester) async {
      await pumpNav(tester);

      // 先选中「事件」
      await tapAndWatch(tester, '事件');
      expect(iconIsMoving(tester, '事件'), isFalse, reason: '它自己已经播完了');

      // 再选「更多」：只有新选中的那一项动，退出的那一项安静
      await tester.tap(find.text('更多'));
      await tester.pump();
      var exitedMoved = false;
      var enteredMoved = false;
      for (var step = 0; step < 5; step += 1) {
        await tester.pump(const Duration(milliseconds: 60));
        if (iconIsMoving(tester, '事件')) exitedMoved = true;
        if (iconIsMoving(tester, '更多')) enteredMoved = true;
      }
      expect(enteredMoved, isTrue, reason: '新选中的那一项要动');
      expect(exitedMoved, isFalse, reason: '退出的那一项不该再播一次');
    });

    testWidgets('灯泡那一下：只在上半圈画发散的光线', (tester) async {
      await pumpNav(tester);

      NavBulbRays? rays() {
        final paints = tester.widgetList<CustomPaint>(
          find.descendant(
            of: find.byKey(navIconKey('灵感')),
            matching: find.byType(CustomPaint),
          ),
        );
        for (final paint in paints) {
          final painter = paint.painter;
          if (painter is NavBulbRays) return painter;
        }
        return null;
      }

      expect(rays(), isNotNull, reason: '灯泡那一项要有光线画层');
      expect(rays()!.progress, 0, reason: '静止时不该画');
      // 屏幕坐标 y 向下：负角度才是"往上"，也就是灯泡的上半圈
      expect(
        NavBulbRays.rayAngles.every((angle) => angle < 0),
        isTrue,
        reason: '灯座在下半圈，那里不该发光',
      );

      // 先离开灵感页，这样接下来才是"变成选中"
      hostKey.currentState!.dragTo(2);
      await tester.pumpAndSettle();

      await tester.tap(find.text('灵感'));
      await tester.pump();
      var brightest = 0.0;
      for (var step = 0; step < 5; step += 1) {
        await tester.pump(const Duration(milliseconds: 60));
        brightest = math.max(brightest, rays()!.progress);
      }
      expect(brightest, greaterThan(0.5), reason: '中途最亮');

      await tester.pumpAndSettle();
      expect(rays()!.progress, 0, reason: '亮完要收干净');
    });

    testWidgets('折线那一下：从起点开始连线，走到画满为止', (tester) async {
      await pumpNav(tester);

      NavIconRevealClipper? clipper() {
        final clips = tester.widgetList<ClipRect>(
          find.descendant(
            of: find.byKey(navIconKey('事件')),
            matching: find.byType(ClipRect),
          ),
        );
        for (final clip in clips) {
          final value = clip.clipper;
          if (value is NavIconRevealClipper) return value;
        }
        return null;
      }

      expect(clipper(), isNotNull, reason: '折线那一项要有"逐步揭开"的裁剪');
      expect(clipper()!.reveal, closeTo(1, 1e-9), reason: '静止时是完整图形');

      await tester.tap(find.text('事件'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      final midway = clipper()!.reveal;
      expect(midway, lessThan(0.99), reason: '途中还没走完');
      expect(midway, greaterThan(0.15), reason: '起点那一小段应当已经出来了');

      await tester.pumpAndSettle();
      expect(clipper()!.reveal, closeTo(1, 1e-9), reason: '走完就是完整图形');
    });

    testWidgets('滑动到别页时，新选中的那一项也会动一下', (tester) async {
      await pumpNav(tester);
      expect(iconIsMoving(tester, '事件'), isFalse);

      hostKey.currentState!.dragTo(2); // 滑到第 2 页（事件）
      await tester.pump();
      var moved = false;
      for (var step = 0; step < 5; step += 1) {
        await tester.pump(const Duration(milliseconds: 60));
        if (iconIsMoving(tester, '事件')) moved = true;
      }
      expect(moved, isTrue);

      await tester.pumpAndSettle();
      expect(iconIsMoving(tester, '事件'), isFalse);
    });
  });
}

class _Host extends StatefulWidget {
  const _Host({super.key, this.disableAnimations = false});

  /// 模拟系统"关闭动画"的无障碍开关（`MediaQuery.disableAnimations`）。
  final bool disableAnimations;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  final ValueNotifier<double> _page = ValueNotifier<double>(0);

  /// 把页面拖到 [page]（可以是小数；真实场景里这就是 `PageController` 的进度）。
  void dragTo(double page) => _page.value = page;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nav = SizedBox(
      width: 320,
      height: 48,
      child: AppBottomNav(
        page: _page,
        // 与真实外壳一致：点某一项 → 页位置跟着过去 → 选中态变化 → 图标动一下
        onSelect: (index) => dragTo(index.toDouble()),
      ),
    );
    if (!widget.disableAnimations) return nav;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: nav,
    );
  }
}
