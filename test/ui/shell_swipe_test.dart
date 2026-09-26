import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';

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
