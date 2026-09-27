import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/color_picker.dart';
import 'package:guideline/ui/common/inline_editor.dart';

import 'scroll_finders.dart';

/// 项目详情页的标题栏、目标 / 两套正文与文案（实机反馈 + Q1/Q2/Q4）：
///   · 标题旁立一根**标识色竖条**（没设色就是灰条），与项目树行首同一个控件；
///   · 正文里不再重复一个「名称」字段，改名收进标题右侧的三个点，
///     点「重命名」后标题栏原地变成输入框，带确认 / 取消；
///   · **项目没有完成态**（Q1）：这一页没有状态胶囊，也没有
///     「还有 N 个子项目未处理」这类提示；
///   · **分类与目标两套正文**（Q2）：分类只有标识色 / 总纲领 / 下级，
///     不出现清单、如何解决、日期，也没有灵感合并入口；
///   · 下级可以**就地展开**，展开后能直接看到并勾选那个下级的实现清单
///     （进它的详情页走展开区里的「打开这个目标」）；
///   · 字段改称「有什么问题 / 思路」与「如何解决」（Q4）；
///   · 字段的**就地编辑默认带确认 / 取消**（Q33）；说明性文字整批收掉，
///     空态只留计数（实机反馈：教程用户自己做）。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_detail_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  /// 从项目 Tab 进到指定项目的详情页（底栏那一项与标题栏文案不同名，直接按底栏找）。
  Future<void> openProject(WidgetTester tester, AppController app, String title) async {
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: find.byType(AppBottomNav), matching: find.text('项目')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).first);
    await tester.pumpAndSettle();
  }

  /// 详情页标题栏里的那根竖条。
  ///
  /// `find.byType` 默认跳过 offstage：被详情页盖住的 Tab 页不在结果里，
  /// 所以这里不用再按路由去区分。
  Finder titleBar() => find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(ProjectColorBar),
      );

  Color? renderedBarColor(WidgetTester tester) {
    final container = tester.widget<Container>(
      find.descendant(of: titleBar(), matching: find.byType(Container)),
    );
    return (container.decoration as BoxDecoration?)?.color;
  }

  testWidgets('详情页标题旁有标识色竖条；没设色的项目用灰条补齐', (tester) async {
    final app = await boot();
    final colored = app.ws.createProject(title: '有色的项目');
    final plain = app.ws.createProject(title: '没色的项目');
    app.run(() => app.ws.setProjectColor(colored.id, '#336699'));
    app.run(() => app.ws.setProjectColor(plain.id, null));

    await openProject(tester, app, '有色的项目');

    expect(titleBar(), findsOneWidget);
    expect(tester.widget<ProjectColorBar>(titleBar()).color, '#336699');
    expect(renderedBarColor(tester), colorOfHex('#336699'));
    expect(find.text('名称'), findsNothing, reason: '标题栏已经写着名字了，正文里不再重复');

    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('没色的项目').first);
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.text('没色的项目'))).colorScheme;
    expect(renderedBarColor(tester), scheme.outlineVariant, reason: '没设色 = 中性灰条');
  });

  testWidgets('重命名收进三个点：标题栏原地变输入框，带确认 / 取消', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '老名字');

    await openProject(tester, app, '老名字');

    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    expect(find.byTooltip('保存'), findsOneWidget);
    expect(find.byTooltip('取消'), findsOneWidget);

    // 改一半放弃：不写盘，标题回到原样
    await tester.enterText(find.byType(TextField).first, '不该保存的名字');
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(project.id)!.title, '老名字');
    expect(find.text('不该保存的名字'), findsNothing);
    expect(find.text('老名字'), findsOneWidget);

    // 改完确认：真的写盘，标题栏跟着变
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '新名字');
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(project.id)!.title, '新名字');
    expect(find.text('新名字'), findsOneWidget);
  });

  testWidgets('重命名清空时不提交：保持原名，不把标题清没', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '别弄丢我');

    await openProject(tester, app, '别弄丢我');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.title, '别弄丢我');
    expect(find.text('别弄丢我'), findsOneWidget);
  });

  testWidgets('字段编辑态默认带确认 / 取消：点取消恢复原值，一个字节都不写盘（Q33）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '有思路的项目');
    app.run(() => app.ws.updateProject(project.id, purpose: '原来的思路'));

    await openProject(tester, app, '有思路的项目');

    final store = File('${tempDir.path}${Platform.pathSeparator}guideline.json');
    final before = store.readAsBytesSync();

    // 空正文不会被收起，所以这一页有两个 `InlineTextField`（思路 + 如何解决）
    await tester.tap(find.text('原来的思路'));
    await tester.pumpAndSettle();

    // `editorActions` 现在默认打开（Q33）：编辑态右侧就有这两个 32×32 的紧凑图标
    expect(find.byTooltip('确认'), findsOneWidget);
    expect(find.byTooltip('取消'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '改了一半的思路');
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.purpose, '原来的思路');
    expect(find.text('原来的思路'), findsOneWidget);
    expect(find.text('改了一半的思路'), findsNothing);
    expect(
      store.readAsBytesSync(),
      before,
      reason: '取消 = 丢掉改动，不能因为点了两个键就白写一次盘',
    );
  });

  testWidgets('项目没有完成态：详情页没有状态胶囊，也没有"还有 N 个子项目未处理"', (tester) async {
    final app = await boot();
    final parent = app.ws.createProject(title: '父项目');
    app.ws.createProject(title: '子项目', parentId: parent.id);

    await openProject(tester, app, '父项目');

    // 状态三态（未完成 / 已完成 / 已搁置）整块拿掉（Q1）
    expect(find.text('状态'), findsNothing);
    expect(find.text('已完成'), findsNothing);
    expect(find.text('已搁置'), findsNothing);
    expect(find.textContaining('未处理'), findsNothing);
    expect(find.textContaining('可以标记完成'), findsNothing);

    // 项目能做的只有"要 / 不要"：归档仍在动作菜单里
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('归档'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('目标详情页：字段改称「有什么问题 / 思路」与「如何解决」（Q4）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标甲');
    app.run(() => app.ws.updateProject(project.id, purpose: '先把口子收窄'));

    await openProject(tester, app, '目标甲');

    expect(find.text('有什么问题 / 思路'), findsOneWidget);
    expect(find.text('如何解决'), findsOneWidget);
    expect(find.text('目的'), findsNothing);
    expect(find.text('实现计划'), findsNothing);
    expect(find.textContaining('先把口子收窄'), findsOneWidget);
  });

  testWidgets('分类详情页：一个总纲领输入框 + 可展开的下级，不出现清单 / 如何解决 / 日期', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    final target = app.ws.createProject(title: '发布 v1', parentId: category.id);
    // 分类要的是「总纲领」——**同一个 `purpose` 字段**，只是换了个标题：
    // 分类里装的是同一个方向的几件事，这个方向理应有一句总纲（实机反馈）
    app.run(
      () => app.ws.updateProject(
        category.id,
        purpose: '这一类都为了把 v1 发出去',
        date: '2026-12-31',
      ),
    );
    // 故意给分类塞上"目标才有"的内容：它一个都不该显示
    app.run(() => app.ws.replaceImplementation(category.id, '分类不该有正文'));
    app.run(() => app.ws.addProjectItem(category.id, '分类不该有清单条'));
    app.run(() => app.ws.addProjectItem(target.id, '目标的一条'));

    await openProject(tester, app, '工作');

    expect(find.text('总纲领'), findsOneWidget);
    expect(find.text('这一类都为了把 v1 发出去'), findsOneWidget);
    expect(find.text('下级'), findsOneWidget);
    expect(find.text('发布 v1'), findsOneWidget);
    // 「汇总」卡已删：那句"含 N 个目标 / 清单 x/y"既不是纲领也不是内容，
    // 数字挪到下级行上，需要时一眼就能看到
    expect(find.text('汇总'), findsNothing);
    expect(find.text('含 1 个目标'), findsNothing);
    expect(find.text('清单 0/1'), findsOneWidget, reason: '进度挂在下一个级行上');

    // 分类上没有的东西
    expect(find.text('有什么问题 / 思路'), findsNothing);
    expect(find.text('如何解决'), findsNothing);
    expect(find.text('实现清单'), findsNothing);
    expect(find.text('分类不该有正文'), findsNothing);
    expect(find.text('分类不该有清单条'), findsNothing);
    // 分类没有日期（《定义与边界》§2.1）：连日期图标都不给
    expect(find.text('日期'), findsNothing);
    expect(find.textContaining('2026-12-31'), findsNothing);
    expect(find.byTooltip('日期：点一下选'), findsNothing);
    // 分类不装灵感：这一页没有灵感区，也没有交接导出
    expect(find.textContaining('待处理灵感'), findsNothing);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('导出交接说明…'), findsNothing);
    expect(find.text('移到其它分类'), findsOneWidget, reason: '分类的动作仍在菜单里');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('分类的下级可以展开：展开后能看到并勾选它的实现清单', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    final target = app.ws.createProject(title: '发布 v1', parentId: category.id);
    app.run(() => app.ws.addProjectItem(target.id, '写好发布说明'));

    await openProject(tester, app, '工作');

    // 收起时只给进度，不给清单内容 —— 一行下级不该把整页撑开
    expect(find.text('写好发布说明'), findsNothing);

    await tester.tap(find.text('发布 v1'));
    await tester.pumpAndSettle();

    expect(find.text('写好发布说明'), findsOneWidget);
    // 就地打勾：与项目页同一个口径（只是打勾，不参与任何判定）
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(target.id)!.items.single.done, isTrue);
    expect(app.ws.findProject(target.id)!.itemsDoneCount, 1);
    expect(find.text('已完成'), findsNothing, reason: '项目没有完成态（Q1）');

    // 勾完不会自己收起来（展开状态挂在 State 上）
    expect(find.text('写好发布说明'), findsOneWidget);

    await tester.tap(find.text('发布 v1'));
    await tester.pumpAndSettle();
    expect(find.text('写好发布说明'), findsNothing);
    expect(app.ws.findProject(target.id)!.items.single.done, isTrue, reason: '收起不会把勾去掉');
  });

  testWidgets('展开区里的「打开这个目标」进的是下级自己的详情页', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    final target = app.ws.createProject(title: '发布 v1', parentId: category.id);
    app.run(() => app.ws.updateProject(target.id, purpose: '发布页还差一个回滚口径'));

    await openProject(tester, app, '工作');
    await tester.tap(find.text('发布 v1'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('打开这个目标'));
    await tester.pumpAndSettle();

    expect(find.text('有什么问题 / 思路'), findsOneWidget);
    expect(find.text('发布页还差一个回滚口径'), findsOneWidget);
  });

  testWidgets('空态只剩计数：下级 0 与"待处理灵感 0"，不再配说明性文字', (tester) async {
    final app = await boot();
    app.ws.createProject(title: '光杆目标');

    await openProject(tester, app, '光杆目标');

    // 说明性文字整批收掉（用户自己做教程）：空态只留标题里的计数
    expect(find.text('下级'), findsOneWidget);
    expect(find.textContaining('还没有下级'), findsNothing);
    await tester.scrollUntilVisible(
      find.text('待处理灵感 0'),
      150,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('待处理灵感 0'), findsOneWidget);
    expect(find.textContaining('去灵感页记一句'), findsNothing);
  });

  testWidgets('新建入口文案随层级：分类下是「新建目标」（复用 InlineComposer）', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    app.ws.createProject(title: '发布 v1', parentId: category.id);

    await openProject(tester, app, '工作');

    expect(find.text('新建目标'), findsOneWidget);
    expect(find.text('新建子项目'), findsNothing, reason: 'Q2：这一层建出来的是目标');
    expect(find.byType(InlineComposer), findsOneWidget, reason: '用现成控件，不新增');

    await tester.tap(find.text('新建目标'));
    await tester.pumpAndSettle();
    final composer = find.ancestor(
      of: find.byType(TextField),
      matching: find.byType(InlineComposer),
    );
    await tester.enterText(
      find.descendant(of: composer, matching: find.byType(TextField)),
      '发布 v2',
    );
    await tester.tap(find.descendant(of: composer, matching: find.byTooltip('添加')));
    await tester.pumpAndSettle();

    final created = app.ws.liveProjects.firstWhere((p) => p.title == '发布 v2');
    expect(created.parentId, category.id, reason: '真的挂在分类下面');
  });
}
