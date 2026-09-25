import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/ui/app_shell.dart';

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
        expect(width, lessThanOrEqualTo(nominal + 12 + 1e-9), reason: '拉伸超过上限');
        if (width > peak) peak = width;
      }
      expect(peak, greaterThan(nominal + 8), reason: '该拉长的时候要看得出来');

      // 「质量小一点」（实机反馈"太粘滞"）：峰值靠前，后半程就收回大半，
      // 而不是一路鼓到最后几帧才追平
      expect(at(0.4).width, greaterThan(at(0.6).width), reason: '峰值应当在前半程');
      expect(at(0.9).width - nominal, lessThan(3), reason: '后段应当已经基本收回');
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

    Future<void> pumpNav(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: _Host(key: hostKey))),
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

    /// 图标那一层当前的缩放倍数（`Transform.scale` 只改绘制，量尺寸量不到）。
    double iconScale(WidgetTester tester, String label) => tester
        .widget<Transform>(find.byKey(navIconKey(label)))
        .transform
        .getMaxScaleOnAxis();

    testWidgets('点某一项：图标弹一下再回到原大小', (tester) async {
      await pumpNav(tester);

      expect(iconScale(tester, '项目'), closeTo(1, 0.001), reason: '静止时就是原大小');

      await tester.tap(find.text('项目'));
      await tester.pump(); // 起帧
      await tester.pump(const Duration(milliseconds: 120)); // 动画中点
      expect(iconScale(tester, '项目'), greaterThan(1.05), reason: '途中应当被放大');

      await tester.pumpAndSettle();
      expect(iconScale(tester, '项目'), closeTo(1, 0.001), reason: '弹完要回到原大小');
    });

    testWidgets('点已经选中的那一项：照样有反馈', (tester) async {
      await pumpNav(tester);

      // 起点就是第 0 页，再点一次"灵感"
      await tester.tap(find.text('灵感'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(iconScale(tester, '灵感'), greaterThan(1.05));

      await tester.pumpAndSettle();
      expect(iconScale(tester, '灵感'), closeTo(1, 0.001));
    });

    testWidgets('滑动到别页时，新选中的那一项也会弹一下', (tester) async {
      await pumpNav(tester);
      expect(iconScale(tester, '事件'), closeTo(1, 0.001));

      hostKey.currentState!.dragTo(2); // 滑到第 2 页（事件）
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(iconScale(tester, '事件'), greaterThan(1.05));

      await tester.pumpAndSettle();
      expect(iconScale(tester, '事件'), closeTo(1, 0.001));
    });
  });
}

class _Host extends StatefulWidget {
  const _Host({super.key});

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
  Widget build(BuildContext context) => SizedBox(
        width: 320,
        height: 48,
        child: AppBottomNav(page: _page, onSelect: (_) {}),
      );
}
