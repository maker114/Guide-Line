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

    // 收成形（280ms）与淡出（200ms）**重叠着放**，所以这两下之后就该空了。
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester.getSize(find.byType(SyncStatusIndicator)),
      Size.zero,
      reason: '放完才真的腾出位置',
    );
  });

  testWidgets('退场：形状还在收的时候就已经开始淡了（两段重叠，不是串行）', (tester) async {
    // 这条钉的是 2026-10-02 按实机反馈改掉的那个问题：
    // 原来写的是「先按原路收回圆环，**收完**再淡出」—— 用户说"最后的消失有点生硬"。
    // 生硬就生硬在：形状收完之后**停在圆环上、透明度还是 1**，然后才开始淡，
    // 视觉上"动一下、停住、再淡掉"。
    //
    // 而原来那条用例只断言"尺寸还占着"与"最后归零" —— **串行改成并行它照样绿**，
    // 所以它守不住这件事。这条专门盯**中途那一帧**：形状还没收完时，
    // 不透明度必须已经小于 1。
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

    await tester.pumpWidget(tree(const AutoSyncState.idle()));
    await tester.pump();

    // 退场总长取 $morphDuration = 280ms。走到 ~200ms（约 0.71）时：
    //   · 形状：还没收完（morph > 0），所以整格还在；
    //   · 透明度：Interval(0.45, 1) 已经过去一半多，必须明显小于 1。
    await tester.pump(const Duration(milliseconds: 200));

    double opacityNow() {
      final widgets = tester.widgetList<Opacity>(
        find.descendant(
          of: find.byType(SyncStatusIndicator),
          matching: find.byType(Opacity),
        ),
      );
      // 最外层那个才是整格的透明度（里面那个是胶囊上的文字）。
      return widgets.first.opacity;
    }

    expect(
      tester.getSize(find.byType(SyncStatusIndicator)).height,
      26,
      reason: '这时候形状还没收完，那一格仍占着',
    );
    expect(
      opacityNow(),
      lessThan(1),
      reason: '形状还在收就已经在淡了 —— 两段必须重叠；等于 1 说明又串行了',
    );
    expect(
      opacityNow(),
      greaterThan(0),
      reason: '也不该已经淡光 —— 淡到最后一段才归零',
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

  // ------------------------------------------------- 成形分两段：先合口再拉伸

  group('成形分两段：先把圆环合上，再把矩形拉长（2026-10-02）', () {
    // 背景：用户反馈"在胶囊出现后会有一点点接缝，你可以试试在由缺口圆环切换为
    // 胶囊形的时候先将圆环闭合然后再拉伸。"
    //
    // 改之前宽度与合口**同时**插值，于是"合口"那一刻正好落在拉伸途中 ——
    // 缺口两端在一个正在变形的形状上相遇，接缝就露在那一下。
    //
    // 这一组是**纯几何**，所以直接调那两个函数，不摆控件 —— 它要守的是
    // "前半段形状不许变"，而不是"某个像素长什么样"。

    test('前半段：拉伸恒为 0（外框一直是正方形，也就是正圆）', () {
      for (final morph in <double>[0, 0.1, 0.25, 0.4, 0.5]) {
        expect(
          stretchProgress(morph),
          0,
          reason: 'morph=$morph 时还不该开始拉伸 —— 先让圆环把口合上',
        );
      }
    });

    test('后半段：合口恒为 1（口已闭上，只把矩形拉长）', () {
      for (final morph in <double>[0.5, 0.6, 0.75, 0.9, 1]) {
        expect(
          closeProgress(morph),
          1,
          reason: 'morph=$morph 时口必须已经合上，不许一边拉一边还有缺口',
        );
      }
    });

    test('两段各自走到头：0 → 全开，1 → 全合 / 全宽', () {
      expect(closeProgress(0), 0, reason: '起手是那个缺口圆环');
      expect(stretchProgress(1), closeTo(1, 1e-9), reason: '收尾是满宽胶囊');
      expect(closeProgress(1), 1);
      expect(stretchProgress(0), 0);
    });

    test('两段都单调不减，而且没有跳变（跳变就是"顿一下"）', () {
      // 注意别把 previous 初始化成 -1：那样第一个点算出来的 Δ 恒为 1，
      // 会误报一个"跳变"（这个坑我踩过一次）。用 null 表示"还没有上一个"。
      double? previousClose;
      double? previousStretch;
      for (var i = 0; i <= 40; i++) {
        final morph = i / 40;
        final close = closeProgress(morph);
        final stretch = stretchProgress(morph);
        if (previousClose != null) {
          expect(close, greaterThanOrEqualTo(previousClose));
        }
        if (previousStretch != null) {
          expect(stretch, greaterThanOrEqualTo(previousStretch));
        }
        expect(
          ((close - (previousClose ?? close)).abs()),
          lessThan(0.2),
          reason: '合口在 morph=$morph 附近跳了一下',
        );
        expect(
          ((stretch - (previousStretch ?? stretch)).abs()),
          lessThan(0.2),
          reason: '拉伸在 morph=$morph 附近跳了一下',
        );
        previousClose = close;
        previousStretch = stretch;
      }
    });
  });
}
