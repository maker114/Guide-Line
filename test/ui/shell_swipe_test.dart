import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/shell_title.dart';

/// 外壳的**左右滑动切页**（实机反馈）：四个页签排成一排，滑过去就换页，
/// 底栏那个胶囊跟着手指走。
///
/// 与"点底栏切页"是两条入口、同一个结果 —— 两条都要钉住。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_swipe_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.ws.createProject(title: '一个项目');
    app.ws.createEvent(name: '一个事件');
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    return app;
  }

  /// 横向滑过 [pages] 页（正数向左、往后翻；负数向右、往前翻）。
  ///
  /// 一次手势只翻一页，所以要翻两页就滑两次 —— 与真机上一致。
  Future<void> swipe(WidgetTester tester, int pages) async {
    final width = tester.getRect(find.byType(PageView)).width;
    for (var i = 0; i < pages.abs(); i += 1) {
      await tester.drag(
        find.byType(PageView),
        Offset(pages > 0 ? -width * 0.6 : width * 0.6, 0),
      );
      await tester.pumpAndSettle();
    }
  }

  /// 胶囊左端**相对底栏**的位置（底栏自己离屏幕左边还有 20dp 外边距）。
  double pillLeft(WidgetTester tester) {
    final bar = tester.getRect(find.byType(AppBottomNav));
    return tester.getRect(find.byKey(navIndicatorKey)).left - bar.left;
  }

  /// 标题栏里的某个东西（`ShellTitle` 自己的子树，不牵连 `AppBar` 别处）。
  Finder inTitle(Finder matching) =>
      find.descendant(of: find.byType(ShellTitle), matching: matching);

  double layerOpacity(WidgetTester tester, int index) => tester
      .widget<Opacity>(
        find.descendant(
          of: find.byKey(shellTitleLayerKey(index)),
          matching: find.byType(Opacity),
        ),
      )
      .opacity;

  /// 图层被画到离原位多远（`Transform.translate` 的平移量，矩阵第 13 个数）。
  double layerDx(WidgetTester tester, int index) => tester
      .widget<Transform>(
        find.descendant(
          of: find.byKey(shellTitleLayerKey(index)),
          matching: find.byType(Transform),
        ),
      )
      .transform
      .storage[12];

  testWidgets('向左滑一下：从灵感页翻到项目页，底栏胶囊跟着过去', (tester) async {
    final app = await boot(tester);
    final cell = tester.getRect(find.byType(AppBottomNav)).width / 4;

    expect(find.text('未处理 0 条'), findsOneWidget, reason: '起点是灵感页');
    expect(pillLeft(tester), closeTo(0, 1));

    await swipe(tester, 1);

    expect(find.text('项目   1'), findsOneWidget, reason: '滑一下应当到项目页');
    expect(pillLeft(tester), closeTo(cell, 1), reason: '胶囊要跟到第 1 格');
    expect(app.prefs.lastTabIndex, 1, reason: '滑过去的页签同样要记住');
  });

  testWidgets('连续滑两下到事件页，再往回滑一下', (tester) async {
    await boot(tester);
    final cell = tester.getRect(find.byType(AppBottomNav)).width / 4;

    await swipe(tester, 2);
    expect(find.text('事件   1'), findsOneWidget);
    expect(pillLeft(tester), closeTo(cell * 2, 1));

    await swipe(tester, -1);
    expect(find.text('项目   1'), findsOneWidget);
    expect(pillLeft(tester), closeTo(cell, 1));
  });

  testWidgets('滑到「更多」页：标题栏与速记按钮跟着换', (tester) async {
    await boot(tester);

    await swipe(tester, 3);

    expect(find.text('主题与背景'), findsOneWidget, reason: '更多页的内容出现了');
    expect(find.text('关于'), findsOneWidget, reason: '标题栏右侧只在更多页出现');
    expect(find.text('速记'), findsOneWidget, reason: '非灵感页才有速记按钮');
  });

  testWidgets('速记按钮是与底栏滑块同一套的胶囊：高 48、宽 = 一格、色相同，且不压底栏（批 B 第 ③ 项）', (tester) async {
    await boot(tester);
    await swipe(tester, 1); // 到项目页：非灵感页才有速记按钮

    final nav = tester.getRect(find.byType(AppBottomNav));
    final pill = tester.getRect(find.byType(CapturePillButton));
    final indicator = tester.getRect(find.byKey(navIndicatorKey));

    expect(pill.height, closeTo(48, 0.01), reason: '与底栏滑块同高（48）');
    expect(
      pill.width,
      closeTo(nav.width / 4, 0.5),
      reason: '宽度 = 底栏一格 = (底栏可用宽 / 4)，与底栏同一套算法',
    );
    expect(
      pill.width,
      closeTo(indicator.width, 0.5),
      reason: '此刻与选中滑块等宽（同一格）',
    );
    expect(
      pill.bottom,
      lessThan(nav.top),
      reason: '速记按钮要抬在底栏上方，不能压住底栏',
    );

    // 形状与颜色：圆角 = 高度一半（24，与滑块共用 `_navRadius`）、
    // 底色 = 底栏滑块那一套 `secondaryContainer`
    final decoration = tester
        .widget<DecoratedBox>(
          find
              .descendant(
                of: find.byType(CapturePillButton),
                matching: find.byType(DecoratedBox),
              )
              .first,
        )
        .decoration as BoxDecoration;
    final scheme =
        Theme.of(tester.element(find.byType(CapturePillButton))).colorScheme;
    expect(decoration.borderRadius, BorderRadius.circular(24));
    expect(decoration.color, scheme.secondaryContainer);
    final indicatorDecoration = tester
        .widget<Container>(find.byKey(navIndicatorKey))
        .decoration as BoxDecoration;
    expect(
      indicatorDecoration.color,
      decoration.color,
      reason: '与底栏滑块同一套色，保证色系统一',
    );

    expect(
      find.descendant(
        of: find.byType(CapturePillButton),
        matching: find.text('速记'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('窄屏 + 1.6 倍字体：一格放不下就只画图标，但 tooltip 与语义标签仍是「速记」', (tester) async {
    // 360 × 780 逻辑像素（常见手机）；1.6 倍字体下一格只有 (360 − 40) / 4 = 80dp
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(CapturePillButton),
        matching: find.text('速记'),
      ),
      findsNothing,
      reason: '一格宽度放不下「图标 + 速记」，这时只画图标',
    );
    expect(
      find.descendant(
        of: find.byType(CapturePillButton),
        matching: find.byIcon(Icons.bolt),
      ),
      findsOneWidget,
    );
    expect(find.byTooltip('速记'), findsOneWidget, reason: 'tooltip 不能跟着文字一起消失');

    final semantics = tester.ensureSemantics();
    expect(
      find.bySemanticsLabel('速记'),
      findsOneWidget,
      reason: '只画图标时，语义标签是唯一能念出「速记」的地方',
    );
    semantics.dispose();

    // 点击行为不变：切到灵感页并把光标放进速记框
    await tester.tap(find.byType(CapturePillButton));
    await tester.pumpAndSettle();
    expect(find.text('未处理 0 条'), findsOneWidget, reason: '点它应当回到灵感页');
    // `focusCapture` 里还挂着一个 450ms 的"再要一次键盘"（HyperOS 实测需要），
    // 让它跑完再收尾 —— 否则测试框架会判"还有 Timer 没结束"
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('点底栏切页与滑动切页结果一致', (tester) async {
    final app = await boot(tester);
    final cell = tester.getRect(find.byType(AppBottomNav)).width / 4;

    await tester.tap(find.text('事件'));
    await tester.pumpAndSettle();
    expect(find.text('事件   1'), findsOneWidget);
    expect(app.prefs.lastTabIndex, 2);
    expect(pillLeft(tester), closeTo(cell * 2, 1));
  });

  testWidgets('拖动切页时标题也跟着走：交叉淡入淡出 + 轻微横移，拖回来原样还原', (tester) async {
    await boot(tester);
    final width = tester.getRect(find.byType(PageView)).width;

    // 静止：只有一个标题，不留动画痕迹（图层 key 也不该存在）
    expect(inTitle(find.text('灵感')), findsOneWidget);
    expect(inTitle(find.byType(Opacity)), findsNothing);
    expect(find.byKey(shellTitleLayerKey(0)), findsNothing);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(Offset(-width * 0.4, 0));
    await tester.pump();

    // 过渡中：两页各一层
    expect(inTitle(find.byType(Opacity)), findsNWidgets(2));
    expect(inTitle(find.text('项目   1')), findsOneWidget,
        reason: '第 1 页那一层的数量要按项目页自己的口径算');
    expect(inTitle(find.text('灵感')), findsOneWidget, reason: '旧标题还在淡出');

    final opacity = <double>[layerOpacity(tester, 0), layerOpacity(tester, 1)];
    final dx = <double>[layerDx(tester, 0), layerDx(tester, 1)];
    expect(opacity[0] + opacity[1], closeTo(1, 1e-9), reason: '两层不透明度互补');
    expect(opacity[1], greaterThan(0.05));
    expect(opacity[1], lessThan(0.95), reason: '手指停在一半，标题也该停在一半');
    expect(dx[0], lessThan(0), reason: '往后翻：旧标题朝左淡出');
    expect(dx[1], greaterThan(0), reason: '往后翻：新标题自右淡入');
    // 位移与不透明度由**同一个数**算出 —— 这正是"跟手、可回退"的根据
    expect(dx[0], closeTo(-shellTitleShift * opacity[1], 1e-9));
    expect(dx[1], closeTo(shellTitleShift * opacity[0], 1e-9));
    expect(dx[0], greaterThanOrEqualTo(-shellTitleShift - 1e-9));
    expect(dx[1], lessThanOrEqualTo(shellTitleShift + 1e-9));

    // 拖回起点：标题**原样**回来（不是靠动画补回来的）
    await gesture.moveBy(Offset(width * 0.4, 0));
    await tester.pump();
    expect(inTitle(find.text('灵感')), findsOneWidget);
    expect(inTitle(find.byType(Opacity)), findsNothing);
    expect(find.byKey(shellTitleLayerKey(1)), findsNothing);

    // 再拖到同一个位置：读数与第一次逐位一致（只看当前值、不看历史）
    await gesture.moveBy(Offset(-width * 0.4, 0));
    await tester.pump();
    expect(layerOpacity(tester, 0), closeTo(opacity[0], 1e-9));
    expect(layerOpacity(tester, 1), closeTo(opacity[1], 1e-9));
    expect(layerDx(tester, 0), closeTo(dx[0], 1e-9));
    expect(layerDx(tester, 1), closeTo(dx[1], 1e-9));

    await gesture.up();
    await tester.pumpAndSettle();
    // 松手落位后同样不留图层
    expect(inTitle(find.byType(Opacity)), findsNothing);
  });

  testWidgets('点底栏切页时标题也在过渡（与翻页同一条时间线）', (tester) async {
    await boot(tester);

    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pump(); // 起帧：ticker 从这一帧开始计时
    await tester.pump(const Duration(milliseconds: 110)); // 220ms 的一半
    expect(inTitle(find.byType(Opacity)), findsNWidgets(2), reason: '点按也该有过渡，不是直接换');
    expect(inTitle(find.text('灵感')), findsOneWidget);
    expect(inTitle(find.text('项目   1')), findsOneWidget);

    await tester.pumpAndSettle();
    expect(inTitle(find.text('项目   1')), findsOneWidget);
    expect(inTitle(find.byType(Opacity)), findsNothing, reason: '落位后收干净');
  });

  /// 点底栏某一项，并在位移沿途逐帧采样指示器（`animateToPage` 是 220ms）。
  Future<List<Rect>> tapAndSample(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text(label)),
    );
    final samples = <Rect>[];
    for (var i = 0; i < 34; i += 1) {
      await tester.pump(const Duration(milliseconds: 8));
      samples.add(tester.getRect(find.byKey(navIndicatorKey)));
    }
    await tester.pumpAndSettle();
    return samples;
  }

  testWidgets('点按切换：指示器轻微过冲（一格行程的 3%~5%）再吸回，落位与页面一致', (tester) async {
    await boot(tester);
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;

    // 灵感 → 事件：跨两格，且目标不是最右那一格（贴边时过冲会被夹在栏内）。
    // 过冲是**按相邻两格之间那一段**算的（几何就是这么喂的），
    // 所以量纲是"一格行程"，与纯函数那条用例同口径。
    final samples = await tapAndSample(tester, '事件');
    final target = bar.left + cell * 3;
    final peak = samples.map((rect) => rect.right).reduce(math.max);

    expect(peak, greaterThan(target + 1),
        reason: '点按应当有过冲；"感觉不到惯性"就是少了这一下');
    expect(peak, lessThanOrEqualTo(target + cell * 0.05 + 0.5),
        reason: '过冲不许超过一格行程的 5%，否则看着像没对准');
    expect(peak, greaterThanOrEqualTo(target + cell * 0.03 - 0.5),
        reason: '过冲也不能小到看不出来');

    // 落位：页面、底栏、标题三者一致（结束值相同，过冲不留错位）
    expect(find.text('事件   1'), findsOneWidget);
    expect(pillLeft(tester), closeTo(cell * 2, 1));
    expect(tester.getRect(find.byKey(navIndicatorKey)).right, closeTo(target, 1));
  });

  testWidgets('点按切到最右那一格：过冲被夹住，胶囊不顶出导航条', (tester) async {
    await boot(tester);
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;

    final samples = await tapAndSample(tester, '更多');
    for (final rect in samples) {
      expect(rect.left, greaterThanOrEqualTo(bar.left - 0.01), reason: '顶出左端');
      expect(rect.right, lessThanOrEqualTo(bar.right + 0.01), reason: '顶出右端');
    }
    expect(pillLeft(tester), closeTo(cell * 3, 1), reason: '照样要正好停在最后一格');
  });

  testWidgets('连点两次：后一次点按的过冲不被前一次的收尾抹掉', (tester) async {
    await boot(tester);
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;

    // 第一次还没跑完就点第二次：前一次的 future 会因为被接管而立刻完成，
    // 收尾时必须认得出"这不是我这一程"，否则后一次就悄悄变成没有过冲的普通位移
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('事件')),
    );
    await tester.pump();

    final target = bar.left + cell * 3;
    var peak = 0.0;
    for (var i = 0; i < 34; i += 1) {
      await tester.pump(const Duration(milliseconds: 8));
      peak = math.max(peak, tester.getRect(find.byKey(navIndicatorKey)).right);
    }
    await tester.pumpAndSettle();
    expect(peak, greaterThan(target + 1), reason: '后一次点按照样应当有过冲');
    expect(pillLeft(tester), closeTo(cell * 2, 1), reason: '最终停在「事件」那一格');
  });

  testWidgets('关闭动画时：点按不过冲、拉伸回到原值，标题直接切换不做位移', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.ws.createProject(title: '一个项目');
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();

    // ---- 标题：不做位移、不留两层，直接切到离得最近的那一页
    final pageWidth = tester.getRect(find.byType(PageView)).width;
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(PageView)),
    );
    await gesture.moveBy(Offset(-pageWidth * 0.7, 0));
    await tester.pump();
    expect(inTitle(find.byType(Transform)), findsNothing, reason: '关闭动画时不做位移');
    expect(inTitle(find.byType(Opacity)), findsNothing, reason: '也不做交叉淡入淡出');
    expect(inTitle(find.text('项目   1')), findsOneWidget,
        reason: '直接切到离得最近的那一页（此刻已经过半）');
    await gesture.up();
    await tester.pumpAndSettle();

    // ---- 底栏：点按不过冲、拉伸回到原值（此刻在项目页，点「事件」走一格）
    final bar = tester.getRect(find.byType(AppBottomNav));
    final cell = bar.width / 4;
    final samples = await tapAndSample(tester, '事件');
    final target = bar.left + cell * 3;

    expect(samples.map((rect) => rect.right).reduce(math.max),
        lessThanOrEqualTo(target + 0.01),
        reason: '关闭动画时点按不该有过冲');
    final peakWidth =
        samples.map((rect) => rect.width).reduce(math.max) - cell;
    expect(peakWidth, greaterThan(3), reason: '退化不是"完全不拉伸"，只是回到原来那一档');
    expect(peakWidth, lessThanOrEqualTo(navStretchMaxReduced + 0.01),
        reason: '拉伸回到原上限 12');
  });

  testWidgets('切过去再切回来不丢状态（保活）', (tester) async {
    final app = await boot(tester);

    // 在灵感页写一半
    await tester.enterText(find.byType(TextField).first, '写到一半的灵感');
    await tester.pumpAndSettle();

    await swipe(tester, 1);
    await swipe(tester, -1);

    expect(
      find.text('写到一半的灵感'),
      findsOneWidget,
      reason: '滑走再滑回来，输入框里的内容不该没',
    );
    expect(app.ws.inspirationInbox, isEmpty, reason: '没点「记下」就不该落库');
  });

  testWidgets('标题栏的项目数不随收起 / 展开变化（只数最外层、不含已归档）', (tester) async {
    final app = await boot(tester); // boot 里已经有一条「一个项目」

    // 根层再加：一个分类（下面挂两个目标）+ 一个独立目标
    final category = app.ws.createProject(title: '分类一');
    app.run(() => app.ws.createProject(title: '目标甲', parentId: category.id));
    app.run(() => app.ws.createProject(title: '目标乙', parentId: category.id));
    app.run(() => app.ws.createProject(title: '独立目标'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    expect(
      find.text('项目   3'),
      findsOneWidget,
      reason: '只数最外层：一个项目 + 分类一 + 独立目标；分类里面那两个目标不算',
    );

    // 收起 / 展开分类一：数字都不该变（原来取的是"画出来的行数"，一收就变小）
    final toggle = find.byTooltip('收起').evaluate().isNotEmpty
        ? find.byTooltip('收起')
        : find.byTooltip('展开');
    await tester.tap(toggle.first);
    await tester.pumpAndSettle();
    expect(find.text('项目   3'), findsOneWidget, reason: '收起之后数字不变');

    // 已归档的根项目不计入
    app.run(() => app.ws.setProjectArchived(category.id, true));
    await tester.pumpAndSettle();
    expect(find.text('项目   2'), findsOneWidget, reason: '归档的那条不再计入');
  });
}
