import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/events/event_detail_page.dart';
import 'package:guideline/ui/projects/project_checklist.dart';

import 'scroll_finders.dart';

/// 项目「实现」清单的界面接线（《数据契约》§3.2.1）：
///   · 清单与正文并存，两块的入口都在项目详情页；
///   · 加条目、打勾、删条目都真的改了数据；
///   · 「从正文拆成条目」把正文按行拆开，且正文本身不动；
///   · 清单卡片的**标题行**挂着「重拆 / 清空」入口 + 进度 n/m（Q32：
///     上一批把这个入口删了，拆错了就没法重来）；条目**点一下就改**（带确认 / 取消）。
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
      scrollable: verticalScrollable,
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
    // Q35 之后又按实机反馈收了一轮：空态只留一句"还没有条目"，
    // 说明性文字整批删掉（用户自己做教程）
    expect(find.text('还没有条目'), findsOneWidget);
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

  testWidgets('编辑条目：点文本就地改，改完写回数据', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目戊');
    app.run(() => app.ws.addProjectItem(project.id, '原来的条目'));

    await openProject(tester, app, '清单项目戊');
    await scrollTo(tester, find.text('原来的条目'));
    // 点一下就地变成输入框（不再弹对话框）
    await tester.tap(find.text('原来的条目'));
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: find.byType(ProjectChecklist),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '改过的条目');
    await tester.tap(find.byTooltip('确认'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.items.single.text, '改过的条目');
  });

  testWidgets('条目：行尾没有改名图标，编辑态补上确认 / 取消', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目辛');
    app.run(() => app.ws.addProjectItem(project.id, '原来的条目'));

    await openProject(tester, app, '清单项目辛');
    await scrollTo(tester, find.text('原来的条目'));

    // 只读态：条目行里不该再有那个"重命名"小铅笔（点这一行本身就是改）
    expect(
      find.descendant(
        of: find.byType(ProjectChecklist),
        matching: find.byIcon(Icons.edit_outlined),
      ),
      findsNothing,
      reason: '点条目就能改，行尾再挂一个图标是多余的记号',
    );

    await tester.tap(find.text('原来的条目'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('确认'), findsOneWidget);
    expect(find.byTooltip('取消'), findsOneWidget);

    final field = find.descendant(
      of: find.byType(ProjectChecklist),
      matching: find.byType(TextField),
    );

    // 取消：改了一半想放弃 —— 数据不动、界面回到原值
    await tester.enterText(field, '改了一半');
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(project.id)!.items.single.text, '原来的条目');
    expect(find.text('原来的条目'), findsOneWidget);
    expect(find.text('改了一半'), findsNothing);
  });

  testWidgets('清单标题行有「重拆 / 清空」入口（Q32）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目壬');
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));

    await openProject(tester, app, '清单项目壬');
    await scrollTo(tester, find.text('重拆 / 清空'));

    // 入口必须**看得见**：上一批把「重拆 / 清空」整个删掉，拆错了就再没有重来入口
    expect(find.text('重拆 / 清空'), findsOneWidget);
    expect(find.byTooltip('清单：按正文重拆 / 清空'), findsOneWidget);
    // 长按那套说明已删（说明性文字整批收掉）；长按本身在下面这个用例里验

    await tester.tap(find.text('重拆 / 清空'));
    await tester.pumpAndSettle();
    expect(find.text('整理清单'), findsOneWidget);
    expect(find.text('按正文重拆'), findsOneWidget);
    expect(find.text('清空清单'), findsOneWidget);

    // 详情页标题栏的「更多」（交接导出等）不受影响，仍在
    expect(find.byTooltip('更多'), findsOneWidget);
  });

  testWidgets('清空清单：二次确认说清正文不受影响；取消不动、确认才清（Q32）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目癸');
    app.run(() => app.ws.updateProject(project.id, implementation: '- 第一步\n- 第二步'));
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));

    await openProject(tester, app, '清单项目癸');
    await scrollTo(tester, find.text('重拆 / 清空'));
    await tester.tap(find.text('重拆 / 清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空清单'));
    await tester.pumpAndSettle();

    // 二次确认：说清删几条、正文一个字都不动
    expect(find.textContaining('会删掉现在这 1 条条目'), findsOneWidget);
    expect(find.textContaining('正文（「如何解决」）不受影响'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(project.id)!.items, hasLength(1), reason: '取消就一条都不该动');

    await tester.tap(find.text('重拆 / 清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空清单'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.items, isEmpty);
    expect(
      reloaded.implementation,
      '- 第一步\n- 第二步',
      reason: '清空清单只清条目，正文（「如何解决」）不受影响',
    );
    expect(find.text('一条条目'), findsNothing);
  });

  testWidgets('按正文重拆：从入口进，说清会替换现有条目，拆完正文不动（Q32）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目丑');
    app.run(() => app.ws.updateProject(project.id, implementation: '- 甲\n- 乙\n- 丙'));
    app.run(() => app.ws.addProjectItem(project.id, '旧的条目'));

    await openProject(tester, app, '清单项目丑');
    await scrollTo(tester, find.text('重拆 / 清空'));
    await tester.tap(find.text('重拆 / 清空'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按正文重拆'));
    await tester.pumpAndSettle();

    // "不可逆的猜测 + 替换现有条目"必须写在确认框里
    expect(find.textContaining('会先清空现在这 1 条'), findsOneWidget);
    expect(find.textContaining('怎么拆是猜的'), findsOneWidget);

    await tester.tap(find.text('重拆'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.items.map((i) => i.text), <String>['甲', '乙', '丙']);
    expect(
      reloaded.implementation,
      '- 甲\n- 乙\n- 丙',
      reason: '重拆是"另存一份结构"，正文本身不该被改写',
    );
    expect(find.text('旧的条目'), findsNothing, reason: '重拆会替换掉现有条目');
  });

  testWidgets('长按条目弹出操作，删除不弹确认', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目己');
    app.run(() => app.ws.addProjectItem(project.id, '要删的条目'));

    await openProject(tester, app, '清单项目己');
    await scrollTo(tester, find.text('要删的条目'));
    // 行尾不再挂三个点：编辑靠点、其余操作靠长按
    expect(
      find.byWidgetPredicate(
        (w) => w is PopupMenuButton<String> && w.tooltip == '条目操作',
      ),
      findsNothing,
      reason: '条目行上的三个点已去掉（实机反馈"意义不明"）',
    );
    await tester.longPress(find.text('要删的条目'));
    await tester.pumpAndSettle();
    expect(find.text('删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.items, isEmpty);
    expect(find.text('要删的条目'), findsNothing);
  });

  testWidgets('清单与「如何解决」并存：正文默认收起，展开后能改', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目庚');
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));
    app.run(() => app.ws.replaceImplementation(project.id, '整理后的整体说明'));

    await openProject(tester, app, '清单项目庚');
    await scrollTo(tester, find.text('如何解决'));

    expect(find.text('一条条目'), findsOneWidget);
    expect(find.text('如何解决'), findsOneWidget);
    expect(find.text('实现计划'), findsNothing, reason: 'Q4：字段改称「如何解决」');
    // 有清单时正文默认收起：内容不在树里
    expect(find.text('整理后的整体说明'), findsNothing);

    await tester.tap(find.text('展开'));
    await tester.pumpAndSettle();
    expect(find.text('整理后的整体说明'), findsOneWidget);
  });

  testWidgets('清单区的 AI 入口与提示都改称「如何解决」（Q4）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目子');
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));

    await openProject(tester, app, '清单项目子');
    await scrollTo(tester, find.text('AI 整理成「如何解决」'));

    expect(find.text('AI 整理成「如何解决」'), findsOneWidget);
    expect(find.text('AI 整理成计划'), findsNothing);
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

    // 生成的内容真的在编辑框里（含「有什么问题 / 思路」与勾选语法）
    final controller = tester
        .widget<TextField>(
          find.descendant(of: find.byType(Scaffold), matching: find.byType(TextField)).first,
        )
        .controller!;
    expect(controller.text, contains('# 项目：交接项目'));
    expect(controller.text, contains('- 有什么问题 / 思路：把状态讲清楚'));
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
  });

  testWidgets('建成任务：选一个事件 → 任务真的建出，条目与正文一个字都没动（Q24）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目A');
    app.run(() => app.ws.addProjectItem(project.id, '写解析层'));
    app.run(() => app.ws.updateProject(project.id, implementation: '先把契约冻结'));
    final event = app.ws.createEvent(name: '发布线');

    await openProject(tester, app, '清单项目A');
    await scrollTo(tester, find.text('写解析层'));
    await tester.longPress(find.text('写解析层'));
    await tester.pumpAndSettle();
    expect(find.text('建成任务…'), findsOneWidget, reason: '规划 → 执行的桥');
    await tester.tap(find.text('建成任务…'));
    await tester.pumpAndSettle();

    // 事件选择器沿用现成的那一个
    await tester.tap(find.text('发布线'));
    await tester.pumpAndSettle();

    expect(app.ws.mainLineOf(event.id).map((t) => t.title), <String>['写解析层']);

    // **条目不删、也不自动打勾**：它只是一份笔记
    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.items.single.text, '写解析层');
    expect(reloaded.items.single.done, isFalse);
    expect(reloaded.implementation, '先把契约冻结', reason: '正文也一个字都不动');

    // 建完要交代"建到哪去了" + 条目还在 + 能跳过去
    expect(find.textContaining('已建成任务：发布线'), findsOneWidget);
    expect(find.textContaining('清单条目留着'), findsOneWidget);
    await tester.tap(find.text('去看看'));
    await tester.pumpAndSettle();
    expect(find.byType(EventDetailPage), findsOneWidget);
  });

  testWidgets('建成任务：一个事件都没有时，说清先去开一条线（Q24）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目B');
    app.run(() => app.ws.addProjectItem(project.id, '写解析层'));

    await openProject(tester, app, '清单项目B');
    await scrollTo(tester, find.text('写解析层'));
    await tester.longPress(find.text('写解析层'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('建成任务…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('先去「事件」里开一条线'), findsOneWidget);
    expect(app.ws.liveTasks, isEmpty);
    expect(app.ws.findProject(project.id)!.items.single.text, '写解析层');
  });
}
