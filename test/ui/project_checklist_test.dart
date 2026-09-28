import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('空清单：只留一句弱提示，"拆"这一步交给 AI', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目甲');
    app.run(() => app.ws.updateProject(project.id, implementation: '第一步\n第二步'));

    await openProject(tester, app, '清单项目甲');

    await scrollTo(tester, find.text('实现'));
    expect(find.text('实现'), findsOneWidget);
    // 空态只留一句"还没有条目"（说明性文字整批删掉，用户自己做教程）
    expect(find.text('还没有条目'), findsOneWidget);
    // 手动「从正文拆成条目」已按实机反馈拿掉（重拆交给 AI），
    // 所以这一侧**不再有那个按钮**
    expect(find.text('从正文拆成条目'), findsNothing);
  });

  testWidgets('清单与文本两种模式：默认给清单，切到文本能看到正文', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目乙');
    app.run(() => app.ws.updateProject(project.id, implementation: '- 第一步\n- 第二步'));

    await openProject(tester, app, '清单项目乙');
    await scrollTo(tester, find.text('实现'));

    // 默认在清单侧（哪怕条目为空 —— 那一侧才有「添加条目」）
    expect(find.text('还没有条目'), findsOneWidget);
    await tester.tap(find.text('文本'));
    await tester.pumpAndSettle();

    expect(find.text('- 第一步\n- 第二步'), findsOneWidget, reason: '文本侧看得到正文原文');
  });

  testWidgets('添加条目：真的进数据（进度 n/m 已按要求撤掉）', (tester) async {
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
    // 「实现」卡片里**不再显示 n/m 进度**（实机反馈：不需要）
    expect(find.text('0/1'), findsNothing);
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
    expect(find.text('1/1'), findsNothing, reason: '进度已经不显示了');
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

  testWidgets('清除已完成条目：只删勾掉的，说清范围与条数，未勾的不动', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    final targetA = app.ws.createProject(title: '发布 v1', parentId: category.id);
    final targetB = app.ws.createProject(title: '复盘', parentId: category.id);
    final itemA = app.ws.addProjectItem(targetA.id, '做完的那条');
    app.run(() => app.ws.addProjectItem(targetA.id, '还没做的那条'));
    final itemB = app.ws.addProjectItem(targetB.id, '也做完了');
    app.run(() => app.ws.setProjectItemDone(targetA.id, itemA.id, true));
    app.run(() => app.ws.setProjectItemDone(targetB.id, itemB.id, true));

    await openProject(tester, app, '工作');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除已完成条目…'));
    await tester.pumpAndSettle();

    // 范围与条数必须写出来（这句话涉及"会丢多少东西"）
    expect(find.textContaining('2 个项目里'), findsOneWidget);
    expect(find.textContaining('已勾选'), findsWidgets);
    expect(find.textContaining('2 条'), findsOneWidget);
    expect(find.textContaining('找不回来'), findsOneWidget);

    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(targetA.id)!.items.map((i) => i.text), <String>['还没做的那条']);
    expect(app.ws.findProject(targetB.id)!.items, isEmpty);
    expect(
      app.ws.findProject(targetA.id)!.items.single.done,
      isFalse,
      reason: '没勾的那条原样留着',
    );
  });

  testWidgets('一条都没勾时，那个菜单项是灰的（点了也没用）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '还没开工');
    app.run(() => app.ws.addProjectItem(project.id, '没做完的一条'));

    await openProject(tester, app, '还没开工');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    final entry = tester.widget<PopupMenuItem<String>>(
      find.ancestor(
        of: find.text('清除已完成条目…'),
        matching: find.byType(PopupMenuItem<String>),
      ),
    );
    expect(entry.enabled, isFalse, reason: '没有已勾选条目时不该让人点进去');
  });

  testWidgets('「重置所有实现」在 ⋮ 里：警告说清范围与代价，只清实现、不碰问题/思路',
      (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目壬');
    app.run(() => app.ws.updateProject(
          project.id,
          purpose: '把这条想法做出来',
          implementation: '- 第一步\n- 第二步',
        ));
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));

    await openProject(tester, app, '清单项目壬');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();

    // 重置**单独一组**，且名字带省略号（表示还会再问一次）
    expect(find.text('重置所有实现…'), findsOneWidget);
    expect(find.text('重置所有项目…'), findsOneWidget);

    await tester.tap(find.text('重置所有实现…'));
    await tester.pumpAndSettle();

    // 明确警告（实机反馈要求）：范围、清什么、清单几条、不能撤销、退回只有一次
    expect(find.textContaining('只会动「清单项目壬」这一个项目'), findsOneWidget);
    expect(find.textContaining('正文与清单条目会被清空'), findsOneWidget);
    expect(find.textContaining('清单 1 条'), findsOneWidget);
    expect(find.textContaining('不能撤销'), findsOneWidget);
    expect(find.textContaining('退回上一版'), findsOneWidget);

    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.implementation, isEmpty, reason: '正文被清空');
    expect(reloaded.items, isEmpty, reason: '清单条目被清空');
    expect(
      reloaded.purpose,
      '把这条想法做出来',
      reason: '「重置所有实现」**不碰**「有什么问题 / 思路」',
    );

    // 给了一次反悔的入口（SnackBar 上的动作）
    await tester.tap(find.text('退回上一版'));
    await tester.pumpAndSettle();

    final reverted = app.ws.findProject(project.id)!;
    expect(reverted.implementation, '- 第一步\n- 第二步', reason: '正文退回来了');
    expect(reverted.items.single.text, '一条条目', reason: '清单条目也退回来了');
  });

  testWidgets('「重置所有项目」连「有什么问题 / 思路」一起清，且留档只值一次反悔',
      (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目丑');
    app.run(() => app.ws.updateProject(
          project.id,
          purpose: '把这条想法做出来',
          implementation: '- 甲\n- 乙',
        ));
    app.run(() => app.ws.addProjectItem(project.id, '旧的条目'));

    await openProject(tester, app, '清单项目丑');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重置所有项目…'));
    await tester.pumpAndSettle();

    // 与「重置所有实现」的差别必须写在警告里
    expect(
      find.textContaining('「有什么问题 / 思路」与实现（正文 + 清单）都会被清空'),
      findsOneWidget,
    );

    await tester.tap(find.text('重置'));
    await tester.pumpAndSettle();

    final reloaded = app.ws.findProject(project.id)!;
    expect(reloaded.purpose, isEmpty);
    expect(reloaded.implementation, isEmpty);
    expect(reloaded.items, isEmpty);
    expect(reloaded.title, '清单项目丑', reason: '名字不动');

    // 退回一次
    await tester.tap(find.text('退回上一版'));
    await tester.pumpAndSettle();
    final reverted = app.ws.findProject(project.id)!;
    expect(reverted.purpose, '把这条想法做出来');
    expect(reverted.implementation, '- 甲\n- 乙');
    expect(reverted.items.single.text, '旧的条目');

    // 一份留档只值一次反悔：再点一次就该说"没有可退回的上一版"
    expect(app.hasResetSnapshot, isFalse);
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

  testWidgets('实现分「清单 / 文本」两种模式：切过去才看得到正文，两个字段都不动', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目庚');
    app.run(() => app.ws.addProjectItem(project.id, '一条条目'));
    app.run(() => app.ws.replaceImplementation(project.id, '整理后的整体说明'));

    await openProject(tester, app, '清单项目庚');
    await scrollTo(tester, find.text('实现'));

    // 有清单时默认就在「清单」这一侧
    expect(find.text('一条条目'), findsOneWidget);
    expect(find.text('清单'), findsOneWidget, reason: '模式切换的分段按钮');
    expect(find.text('文本'), findsOneWidget);
    expect(find.text('整理后的整体说明'), findsNothing, reason: '另一侧的内容不画出来');

    await tester.tap(find.text('文本'));
    await tester.pumpAndSettle();

    expect(find.text('整理后的整体说明'), findsOneWidget);
    expect(find.text('一条条目'), findsNothing, reason: '二选一：切过去就只看另一种');
    // **切模式不清空**：清单还在数据里
    expect(app.ws.findProject(project.id)!.items.single.text, '一条条目');
    expect(app.ws.findProject(project.id)!.implementation, '整理后的整体说明');
  });

  testWidgets('文本模式有「全部复制」：拷走的是正文全文', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '清单项目辛');
    app.run(() => app.ws.replaceImplementation(project.id, '整理后的整体说明'));

    await openProject(tester, app, '清单项目辛');
    await scrollTo(tester, find.text('实现'));

    // 这一块默认给「清单」，先切到「文本」才看得到正文与复制键
    await tester.tap(find.text('文本'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('全部复制'));

    // 把剪贴板的内容记下来（测试环境下 `Clipboard` 走的是平台通道）
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await tester.tap(find.text('全部复制'));
    await tester.pumpAndSettle();

    expect(copied, '整理后的整体说明');
    expect(find.text('已复制'), findsOneWidget, reason: '复制要有反馈，不然看不出成功没成功');
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
