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
          barWidth: barWidth,
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

    test('途中被拉长：起步与落位都不鼓，中间最鼓且不超上限', () {
      expect(at(0.02).width, lessThan(nominal + 2), reason: '起步不该突然弹宽');
      expect(at(0.98).width, lessThan(nominal + 2), reason: '落位前应当收回');
      expect(at(0.5).width, closeTo(nominal + 20, 1e-9), reason: '中途最鼓');

      for (var step = 0; step <= 20; step += 1) {
        final width = at(step / 20).width;
        expect(width, greaterThanOrEqualTo(nominal - 1e-9));
        expect(width, lessThanOrEqualTo(nominal + 20 + 1e-9));
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
    /// 一个能改 index 的宿主：真实用法里 index 由 AppShell 传进来，行为一致。
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

      // 跳到最后一格：右端与外部胶囊右内缘齐平
      hostKey.currentState!.select(3);
      await tester.pumpAndSettle();
      expect(bar().right - pill().right, closeTo(0, 0.01));
      expect(pill().width, closeTo(bar().width / 4, 0.01));
    });

    testWidgets('切页签时胶囊滑过去，途中被拉长', (tester) async {
      await pumpNav(tester);

      final startLeft = tester.getRect(find.byKey(navIndicatorKey)).left;
      hostKey.currentState!.select(3);
      await tester.pump(); // 起帧：动画从 0 开始
      await tester.pump(const Duration(milliseconds: 90));

      final mid = tester.getRect(find.byKey(navIndicatorKey));
      final nominal = tester.getRect(find.byType(AppBottomNav)).width / 4;
      expect(mid.left, greaterThan(startLeft), reason: '应当已经在向右滑');
      expect(mid.width, greaterThan(nominal), reason: '途中应当被拉长');
      expect(mid.width - nominal, lessThanOrEqualTo(20 + 0.01), reason: '拉伸超过上限');

      await tester.pumpAndSettle();
      final settled = tester.getRect(find.byKey(navIndicatorKey));
      expect(settled.width, closeTo(nominal, 0.01), reason: '落位后要收回原宽');
      expect(settled.left, closeTo(nominal * 3, 0.01));
    });

    testWidgets('只是重建（index 没变）不会重新播动画', (tester) async {
      await pumpNav(tester);
      hostKey.currentState!.select(2);
      await tester.pumpAndSettle();

      final before = tester.getRect(find.byKey(navIndicatorKey));
      hostKey.currentState!.rebuild(); // 父级因别的原因重建
      await tester.pump();
      final after = tester.getRect(find.byKey(navIndicatorKey));
      expect(after, before);
    });
  });
}

class _Host extends StatefulWidget {
  const _Host({super.key});

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int _index = 0;

  void select(int index) => setState(() => _index = index);

  void rebuild() => setState(() {});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 320,
        height: 48,
        child: AppBottomNav(index: _index, onSelect: select),
      );
}
