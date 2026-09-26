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
///   · **分类与目标两套正文**（Q2）：分类只有名字 / 标识色 / 下级 / 汇总，
///     不出现目的、清单、如何解决、日期，也没有灵感合并入口；
///   · 字段改称「有什么问题 / 思路」与「如何解决」（Q4）；
///   · 字段的**就地编辑默认带确认 / 取消**（Q33），空态文案顺口一点（Q35）。
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

  testWidgets('分类详情页：只有名字 / 标识色 / 下级 / 汇总，不出现目的 / 清单 / 如何解决 / 日期', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    final target = app.ws.createProject(title: '发布 v1', parentId: category.id);
    // 故意给分类塞上"目标才有"的内容：它一个都不该显示
    app.run(() => app.ws.updateProject(category.id, purpose: '分类不该有目的', date: '2026-12-31'));
    app.run(() => app.ws.replaceImplementation(category.id, '分类不该有正文'));
    app.run(() => app.ws.addProjectItem(category.id, '分类不该有清单条'));
    // 目标自己有清单 → 汇总里能算出来
    app.run(() => app.ws.addProjectItem(target.id, '目标的一条'));

    await openProject(tester, app, '工作');

    expect(find.text('汇总'), findsOneWidget);
    expect(find.text('含 1 个目标'), findsOneWidget);
    expect(find.text('清单 0/1 已完成'), findsOneWidget);
    expect(find.text('下级'), findsOneWidget);
    expect(find.text('发布 v1'), findsOneWidget);

    // 分类上没有的东西
    expect(find.text('有什么问题 / 思路'), findsNothing);
    expect(find.text('如何解决'), findsNothing);
    expect(find.text('实现清单'), findsNothing);
    expect(find.text('分类不该有目的'), findsNothing);
    expect(find.text('分类不该有正文'), findsNothing);
    expect(find.text('分类不该有清单条'), findsNothing);
    expect(find.text('日期'), findsNothing);
    expect(find.textContaining('2026-12-31'), findsNothing);
    // 分类不装灵感：这一页没有灵感区，也没有交接导出
    expect(find.textContaining('待处理灵感'), findsNothing);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('导出交接说明…'), findsNothing);
    expect(find.text('移到其它分类'), findsOneWidget, reason: '分类的动作仍在菜单里');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('空态文案：下级与灵感都顺口说一句"现在是什么情况"（Q35）', (tester) async {
    final app = await boot();
    app.ws.createProject(title: '光杆目标');

    await openProject(tester, app, '光杆目标');

    // 「没有下级 = 目标」这条口径本来就该让用户看到，比干巴巴一句"还没有下级项目"有用
    expect(find.text('还没有下级 —— 现在它自己就是一个目标。'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('这个项目下没有待处理灵感。想到什么，去灵感页记一句。'),
      150,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();
    expect(find.text('这个项目下没有待处理灵感。想到什么，去灵感页记一句。'), findsOneWidget);
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
