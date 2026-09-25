import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';

/// 项目「实现」清单的界面接线（设计文档 §1.3）：
///   · 清单与正文并存，两块的入口都在项目详情页；
///   · 加条目、打勾、删条目都真的改了数据；
///   · 「从正文拆成条目」把正文按行拆开，且正文本身不动。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_checklist_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  /// 从项目 Tab 进到指定项目的详情页。
  Future<void> openProject(WidgetTester tester, AppController app, String title) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('项目'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  Future<void> scrollTo(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
  }

  testWidgets('空清单：给出引导，并说明还能从正文拆', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目甲');
    app.run(() => app.ws.updateProject(project.id, implementation: '第一步\n第二步'));

    await openProject(tester, app, '清单项目甲');

    await scrollTo(tester, find.text('实现清单'));
    expect(find.text('实现清单'), findsOneWidget);
    expect(find.textContaining('还没有条目'), findsOneWidget);
    expect(find.text('从正文拆成条目'), findsOneWidget, reason: '正文非空时才给这个入口');
  });

  testWidgets('点「从正文拆成条目」：拆出条目，正文原样保留', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目乙');
    app.run(() => app.ws.updateProject(project.id, implementation: '- 第一步\n- 第二步'));

    await openProject(tester, app, '清单项目乙');
    await scrollTo(tester, find.text('从正文拆成条目'));
    await tester.tap(find.text('从正文拆成条目'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.items.map((i) => i.text), <String>['第一步', '第二步']);
    expect(
      reloaded.implementation,
      '- 第一步\n- 第二步',
      reason: '拆是"另存一份结构"，正文不该被改写',
    );
    expect(find.text('第一步'), findsOneWidget);
  });

  testWidgets('添加条目：真的进数据，并显示进度', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目丙');

    await openProject(tester, app, '清单项目丙');
    await scrollTo(tester, find.text('添加条目'));
    await tester.tap(find.text('添加条目'));
    await tester.pumpAndSettle();

    final field = find.byType(TextField).last;
    await tester.enterText(field, '写解析层');
    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.items.single.text, '写解析层');
    // 进度文案现在是卡片标题右侧的 n/m（原来写作「n/m 已完成」）
    expect(find.text('0/1'), findsWidgets);
  });

  testWidgets('打勾：只改勾选状态，项目状态不受影响', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目丁');
    app.run(() => app.ws.addProjectItem(project.id, '唯一的条目'));

    await openProject(tester, app, '清单项目丁');
    await scrollTo(tester, find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.items.single.done, isTrue);
    expect(reloaded.itemsDoneCount, 1);
    expect(
      reloaded.status,
      NodeStatus.pending,
      reason: '勾完清单也不该把项目变成已完成 —— 清单不参与判定',
    );
    expect(find.text('1/1'), findsWidgets);
  });

  testWidgets('编辑条目：弹窗改完写回数据', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目戊');
    app.run(() => app.ws.addProjectItem(project.id, '原来的条目'));

    await openProject(tester, app, '清单项目戊');
    await scrollTo(tester, find.text('原来的条目'));
    await tester.tap(find.text('原来的条目'));
    await tester.pumpAndSettle();

    expect(find.text('编辑条目'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '改过的条目');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.items.single.text, '改过的条目');
  });

  testWidgets('删除条目不弹确认，直接删掉', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目己');
    app.run(() => app.ws.addProjectItem(project.id, '要删的条目'));

    await openProject(tester, app, '清单项目己');
    await scrollTo(tester, find.text('要删的条目'));
    // 页面上有好几个「更多」（清单工具条、条目、正文），要精确定位到**条目那一行**的
    final itemMenu = find.byWidgetPredicate(
      (w) => w is PopupMenuButton<String> && w.tooltip == '条目操作',
    );
    expect(itemMenu, findsOneWidget);
    await tester.tap(find.descendant(of: itemMenu, matching: find.byIcon(Icons.more_vert)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.items, isEmpty);
    expect(find.text('要删的条目'), findsNothing);
  });

  testWidgets('清单与正文并存：正文默认收起，展开后能改', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目庚');
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));
    app.run(() => app.ws.replaceImplementation(project.id, '整理后的整体说明'));

    await openProject(tester, app, '清单项目庚');
    await scrollTo(tester, find.text('实现正文'));

    expect(find.text('一条条目'), findsOneWidget);
    expect(find.text('实现正文'), findsOneWidget);
    // 有清单时正文默认收起：内容不在树里
    expect(find.text('整理后的整体说明'), findsNothing);

    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(find.text('整理后的整体说明'), findsOneWidget);
  });

  testWidgets('导出交接说明：菜单入口 → 预览页能看到生成的内容与隐私提醒', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '交接项目');
    app.run(() => app.ws.updateProject(project.id, purpose: '把状态讲清楚'));
    app.run(() => app.ws.addProjectItem(project.id, '已做的一条'));
    app.run(() => app.ws.setProjectItemDone(
          project.id,
          app.ws.findProject(project.id)!.items.single.id,
          true,
        ));

    await openProject(tester, app, '交接项目');

    // 入口在 AppBar 的「更多」里
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('导出交接说明…'), findsOneWidget);
    await tester.tap(find.text('导出交接说明…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('交接说明 · 交接项目'), findsOneWidget);
    expect(find.textContaining('不想给出去的部分删掉'), findsOneWidget);
    expect(find.textContaining('文件会离开这台手机'), findsOneWidget, reason: '必须提醒隐私');
    expect(find.text('导出为 .md'), findsOneWidget);

    // 生成的内容真的在编辑框里（含目的与勾选语法）
    final controller = tester
        .widget<TextField>(
          find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first,
        )
        .controller!;
    expect(controller.text, contains('# 项目：交接项目'));
    expect(controller.text, contains('- 目的：把状态讲清楚'));
    expect(controller.text, contains('- [x] 已做的一条'));
  });

  testWidgets('预览页内容可编辑（导出前能删掉不想外发的部分）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '可编辑预览');
    app.run(() => app.ws.updateProject(project.id, purpose: '这句不想给出去'));

    await openProject(tester, app, '可编辑预览');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出交接说明…'));
    await tester.pumpAndSettle();

    final field = find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first;
    await tester.enterText(field, '# 只留这一行\n');
    await tester.pumpAndSettle();

    final controller = tester.widget<TextField>(field).controller!;
    expect(controller.text, '# 只留这一行\n');
    expect(controller.text, isNot(contains('不想给出去')));
    expect(project.id, isNotEmpty);
  });
}
