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
