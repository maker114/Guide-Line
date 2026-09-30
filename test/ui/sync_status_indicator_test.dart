import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/auto_sync_state.dart';
import 'package:guideline/ui/common/diff_colors.dart';
import 'package:guideline/ui/common/sync_status_indicator.dart';

/// 标题栏右侧那枚自动同步指示器（handoff 双端同步 #87c57e）的外观。
///
/// 用户口径（2026-09-30）：转圈 → 完成时**向左拉伸成胶囊**并变绿、显示提交号；
/// 没能提交就显示对应原因。三条要守住：
///   · 静默时**不占位**（没在同步就别在标题栏留一块空位）；
///   · 在传时是"缺口圆环"，且不带文字（还没结果，写什么都早）；
///   · 成了是**绿色胶囊 + 提交号**，没成是红色调 + 点一下看原因。
void main() {
  Future<void> pumpIndicator(
    WidgetTester tester,
    AutoSyncState state, {
    VoidCallback? onShowReason,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text('项目'),
            actions: <Widget>[SyncStatusIndicator(state: state, onShowReason: onShowReason)],
          ),
        ),
      ),
    );
    // 拖完 AnimatedSize / AnimatedSwitcher 的过场；在传态不能 settle（圆环永远在转）。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  BoxDecoration pillDecoration(WidgetTester tester) {
    final container = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    return container.decoration! as BoxDecoration;
  }

  testWidgets('静默：什么都不画、也不占位', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.idle());

    expect(find.byType(AnimatedContainer), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(Text), findsOneWidget, reason: '标题栏里只有标题那一个 Text');
    expect(
      tester.getSize(find.byType(SyncStatusIndicator)),
      Size.zero,
      reason: '没在同步就一点位置都不该占',
    );
  });

  testWidgets('在传：缺口圆环在转，还没有文字', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.running());

    final ring = find.byType(CircularProgressIndicator);
    expect(ring, findsOneWidget);
    expect(tester.getSize(ring), const Size(20, 20));
    final indicator = tester.widget<CircularProgressIndicator>(ring);
    expect(indicator.strokeWidth, 2.4);
    expect(
      tester.widget<AnimatedContainer>(find.byType(AnimatedContainer)).constraints?.maxHeight,
      26,
      reason: '转的时候就是个圆，高度先占好，回头才好往左长',
    );
    expect(find.text('未同步'), findsNothing, reason: '还没结果，别说丧气话');
    expect(find.text('已同步'), findsNothing);
  });

  testWidgets('传完了：绿色胶囊 + 提交号', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.done('abc1234'));

    expect(find.text('abc1234'), findsOneWidget, reason: '短码，与同步页那台屏上看到的同一串');
    expect(find.byType(CircularProgressIndicator), findsNothing);

    final decoration = pillDecoration(tester);
    expect(
      decoration.color,
      DiffColors.light.addedBackground,
      reason: '"完成上传"是绿的那一头，和差异面板里的绿是同一套色',
    );
    expect(
      decoration.borderRadius,
      BorderRadius.circular(13),
      reason: '高度 26 全圆角 = 胶囊',
    );
  });

  testWidgets('传完了但记账里没有提交号：退化成「已同步」，不写半截空话', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.done(''));

    expect(find.text('已同步'), findsOneWidget);
  });

  testWidgets('没传成：红色调 + 「未同步」，点一下看原因', (tester) async {
    var taps = 0;
    await pumpIndicator(
      tester,
      const AutoSyncState.failed('连不上 GitHub：检查网络或代理设置'),
      onShowReason: () => taps += 1,
    );

    expect(find.text('未同步'), findsOneWidget);
    final scheme = Theme.of(tester.element(find.byType(SyncStatusIndicator))).colorScheme;
    expect(pillDecoration(tester).color, scheme.errorContainer, reason: '没成就是红的');
    expect(find.textContaining('连不上'), findsNothing, reason: '原因放进弹窗，别把标题栏挤爆');

    await tester.tap(find.text('未同步'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('没传成但没给说明入口：只是块牌子，不假装能点', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.failed('原因'));

    expect(find.text('未同步'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });

  test('状态对象自己说清楚：四个相位、同一个值相等', () {
    expect(const AutoSyncState.idle().isVisible, isFalse);
    expect(const AutoSyncState.running().isVisible, isTrue);
    expect(const AutoSyncState.done('abc1234').isVisible, isTrue);
    expect(const AutoSyncState.failed('连不上').isVisible, isTrue);
    expect(const AutoSyncState.running().isRunning, isTrue);
    expect(const AutoSyncState.done('abc1234').isRunning, isFalse);
    expect(const AutoSyncState.done('abc1234'), const AutoSyncState.done('abc1234'));
    expect(const AutoSyncState.done('abc1234').hashCode, const AutoSyncState.done('abc1234').hashCode);
    expect(
      const AutoSyncState.failed('连不上 GitHub：检查网络或代理设置').reason,
      contains('连不上'),
      reason: '失败要把原话说出来，不能只剩一句"同步失败"',
    );
  });
}
