import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/auto_sync_state.dart';
import 'package:guideline/ui/common/diff_colors.dart';
import 'package:guideline/ui/common/sync_status_indicator.dart';

/// 标题栏右侧那枚自动同步指示器（handoff 双端同步 #87c57e）的外观。
///
/// 用户口径（2026-09-30，见 ADR-093）：在传是**缺口圆环**；传完了同一支描边
/// **向左拉长成绿色胶囊**并摆出提交码；这次没传是黄胶囊（点开看原话）；
/// 真的失败才是红；没事就整块不出现。五条要守住：
///   · 静默时**不占位**（没在同步就别在标题栏留一块空位）；
///   · 在传时不带文字（还没结果，写什么都早），且那一格就是 26 的圆；
///   · 成了是**绿色胶囊 + 提交码**，没成是黄、真失败是红，两档都不新增颜色；
///   · 黄/红要能点开看原因原话（写进语义标签，弹窗由外壳接）；
///   · 打回静默时是**收回圆环再淡出**，不是"啪"地不见。
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
            actions: <Widget>[
              SyncStatusIndicator(state: state, onShowReason: onShowReason),
            ],
          ),
        ),
      ),
    );
    // 拖完进入(180ms)与成形(280ms)两段过场。在传态不能 settle：圆环一直在转。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder inIndicator(Finder matching) => find.descendant(
        of: find.byType(SyncStatusIndicator),
        matching: matching,
      );

  ColorScheme schemeOf(WidgetTester tester) =>
      Theme.of(tester.element(find.byType(SyncStatusIndicator))).colorScheme;

  testWidgets('静默：什么都不画、也不占位', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.idle());

    expect(inIndicator(find.byType(CustomPaint)), findsNothing);
    expect(inIndicator(find.byType(Text)), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    expect(
      tester.getSize(find.byType(SyncStatusIndicator)),
      Size.zero,
      reason: '没在同步就一点位置都不该占（两边一样、开关关着都走这一态）',
    );
  });

  testWidgets('在传：缺口圆环在转，一个字都不写', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.running());

    expect(inIndicator(find.byType(CustomPaint)), findsOneWidget);
    expect(
      inIndicator(find.byType(Text)),
      findsNothing,
      reason: '还没结果，写"同步中"也只是猜',
    );
    expect(
      tester.getSize(find.byType(SyncStatusIndicator)),
      const Size(36, 26),
      reason: '那一格是 26 的圆，右边留 10 的白（用户说圆环原来偏右）',
    );
  });

  testWidgets('传完了：绿色胶囊 + 提交码（7 位短码）', (tester) async {
    const state = AutoSyncState.done('abcdef1234567890');
    await pumpIndicator(tester, state);

    expect(find.text('abcdef1'), findsOneWidget, reason: '短码，与同步页那台屏上看到的前 7 位对齐');
    expect(inIndicator(find.byType(Text)), findsOneWidget);

    final context = tester.element(find.byType(SyncStatusIndicator));
    expect(
      SyncStatusIndicator.backgroundOf(context, state),
      DiffColors.light.addedBackground,
      reason: '"传上去了"是绿的那一头，和差异面板里的绿是同一套色',
    );
    expect(
      SyncStatusIndicator.foregroundOf(context, state),
      DiffColors.light.addedForeground,
    );
  });

  testWidgets('传完了但记账里没有提交号：写「已同步」，不编一个码出来', (tester) async {
    await pumpIndicator(tester, const AutoSyncState.done(''));

    expect(find.text('已同步'), findsOneWidget);
    expect(
      SyncStatusIndicator.textOf(const AutoSyncState.done('')),
      '已同步',
      reason: '老记账（1.8.5 及以前）没有码，只能说"已同步"',
    );
  });

  testWidgets('没传成（黄）：胶囊上写短话，原因留给点开看', (tester) async {
    const state = AutoSyncState.blocked(
      label: '云端有更新',
      reason: '远程比本地新：远程 2026-09-30 09:00（3 条），本地 2026-09-29 20:00（1 条）。',
    );
    var taps = 0;
    final handle = tester.ensureSemantics();
    await pumpIndicator(tester, state, onShowReason: () => taps += 1);

    expect(find.text('云端有更新'), findsOneWidget);
    expect(
      find.textContaining('远程比本地新'),
      findsNothing,
      reason: '原因放进弹窗，别把标题栏那一格挤爆',
    );
    expect(
      SyncStatusIndicator.backgroundOf(
        tester.element(find.byType(SyncStatusIndicator)),
        state,
      ),
      DiffColors.light.modifiedBackground,
      reason: '黄 = "这次没传，你看一眼"，跟需求③给"修改"加的黄色是同一对',
    );
    expect(
      find.bySemanticsLabel('云端有更新：远程比本地新：远程 2026-09-30 09:00（3 条），本地 2026-09-29 20:00（1 条）。'),
      findsOneWidget,
      reason: '读屏要把原话读出来，不能只剩"同步有问题"',
    );

    await tester.tap(find.text('云端有更新'));
    await tester.pump();
    expect(taps, 1);
    handle.dispose();
  });

  testWidgets('连不上 GitHub：固定的那句「GitHub 未连接」，也是黄的', (tester) async {
    const state = AutoSyncState.offline('连不上 GitHub：检查网络或代理设置');
    await pumpIndicator(tester, state);

    expect(find.text('GitHub 未连接'), findsOneWidget);
    expect(
      SyncStatusIndicator.backgroundOf(
        tester.element(find.byType(SyncStatusIndicator)),
        state,
      ),
      DiffColors.light.modifiedBackground,
      reason: '连不上不是"失败"，是"这次没传"（需求⑤）',
    );
  });

  testWidgets('真失败：红色调 + 「未同步」', (tester) async {
    const state = AutoSyncState.failed('Token 不对：去同步页换一个');
    await pumpIndicator(tester, state);

    expect(find.text('未同步'), findsOneWidget);
    expect(
      SyncStatusIndicator.backgroundOf(
        tester.element(find.byType(SyncStatusIndicator)),
        state,
      ),
      schemeOf(tester).errorContainer,
      reason: '红只留给"这次真的失败了"',
    );
  });

  testWidgets('没给说明入口：只是块牌子，不假装能点', (tester) async {
    await pumpIndicator(
      tester,
      const AutoSyncState.failed('Token 不对：去同步页换一个'),
    );

    expect(find.text('未同步'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('黄态没带原因：同样不装成能点', (tester) async {
    var taps = 0;
    await pumpIndicator(
      tester,
      const AutoSyncState.blocked(label: '本地有改动', reason: ''),
      onShowReason: () => taps += 1,
    );

    expect(find.text('本地有改动'), findsOneWidget);
    expect(find.byType(InkWell), findsNothing, reason: '点开也没东西可看，就别做成可点的');
    expect(taps, 0);
  });

  testWidgets('一露面就是胶囊：启动静默比对时不播圆环那一段', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SyncStatusIndicator(
            state: AutoSyncState.blocked(label: '云端有更新', reason: '原因'),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      tester.getSize(find.byType(SyncStatusIndicator)).width,
      greaterThan(26),
      reason: '开机那一次没有"从圆环长出来"的过程，第一帧就该是能写字那么宽',
    );
    expect(find.text('云端有更新'), findsOneWidget);
  });

  testWidgets('打回静默：先收回圆环再淡出，不是"啪"地不见', (tester) async {
    // 两帧都用同一棵树：换成另一棵树会让这一格重建（initState），
    // 那就测不到"退场"这条路径了。
    Widget tree(AutoSyncState state) => MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              title: const Text('项目'),
              actions: <Widget>[SyncStatusIndicator(state: state)],
            ),
          ),
        );

    await tester.pumpWidget(tree(const AutoSyncState.done('abcdef1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('abcdef1'), findsOneWidget);

    await tester.pumpWidget(tree(const AutoSyncState.idle()));
    await tester.pump();
    expect(
      tester.getSize(find.byType(SyncStatusIndicator)).height,
      26,
      reason: '退场放到一半还占着那一格（先按原路收回圆环，再淡出）',
    );

    // 收成形（280ms）→ 淡出（200ms）
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getSize(find.byType(SyncStatusIndicator)),
      Size.zero,
      reason: '放完才真的腾出位置',
    );
  });

  test('状态对象自己说清楚：六个相位、同一个值相等', () {
    expect(const AutoSyncState.idle().isVisible, isFalse);
    expect(const AutoSyncState.running().isVisible, isTrue);
    expect(const AutoSyncState.done('abcdef1').isVisible, isTrue);
    expect(
      const AutoSyncState.blocked(label: '云端有更新', reason: '原因').isVisible,
      isTrue,
    );
    expect(const AutoSyncState.offline('连不上').isVisible, isTrue);
    expect(const AutoSyncState.failed('连不上').isVisible, isTrue);

    expect(const AutoSyncState.running().isRunning, isTrue);
    expect(const AutoSyncState.done('abcdef1').isRunning, isFalse);

    expect(const AutoSyncState.done('abcdef1'), const AutoSyncState.done('abcdef1'));
    expect(
      const AutoSyncState.done('abcdef1').hashCode,
      const AutoSyncState.done('abcdef1').hashCode,
    );
    expect(
      const AutoSyncState.done('abcdef1'),
      isNot(const AutoSyncState.blocked(label: '云端有更新', reason: '原因')),
      reason: '相位不同就是不同的状态，动画才会重播',
    );

    expect(
      const AutoSyncState.blocked(label: '云端有更新', reason: '远程比本地新').hasReason,
      isTrue,
    );
    expect(const AutoSyncState.running().hasReason, isFalse);

    expect(
      const AutoSyncState.failed('连不上 GitHub：检查网络或代理设置').reason,
      contains('连不上'),
      reason: '失败要把原话说出来，不能只剩一句"同步失败"',
    );
    expect(
      const AutoSyncState.offline('连不上 GitHub：检查网络或代理设置').label,
      'GitHub 未连接',
      reason: '需求⑤要的就是这一句，不随原话变',
    );
  });
}
