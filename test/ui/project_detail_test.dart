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

  testWidgets('目标详情页：字段改称「有什么问题 / 思路」，实现分「清单 / 文本」两种模式', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标甲');
    app.run(() => app.ws.updateProject(project.id, purpose: '先把口子收窄'));

    await openProject(tester, app, '目标甲');

    expect(find.text('有什么问题 / 思路'), findsOneWidget);
    expect(find.text('目的'), findsNothing);
    expect(find.text('实现计划'), findsNothing);
    expect(find.textContaining('先把口子收窄'), findsOneWidget);

    // 实现那一块：标题 + 二选一的分段按钮（不再是"实现清单 + 如何解决"两张卡）
    expect(find.text('实现'), findsOneWidget);
    expect(find.text('清单'), findsOneWidget);
    expect(find.text('文本'), findsOneWidget);
    expect(
      find.text('如何解决'),
      findsNothing,
      reason: 'ADR-077：整段正文并进「实现 · 文本」那一侧，不再单独占一张卡',
    );
  });

  testWidgets('目标的日期设上之后能在日期面板里清掉（实机反馈：设了就取消不掉）', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '带日期的目标');
    app.run(() => app.ws.updateProject(project.id, date: '2099-05-01'));

    await openProject(tester, app, '带日期的目标');

    // 日期入口就是那颗图标（不在任何菜单里）
    await tester.tap(find.byIcon(Icons.event_available_outlined));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前：'), findsOneWidget);
    await tester.tap(find.text('清除日期'));
    await tester.pumpAndSettle();

    expect(
      app.ws.findProject(project.id)!.date,
      isNull,
      reason: '设过的日期必须能取消掉 —— 从前清除只挂在长按上，而提示也写在同一个长按的 tooltip 里',
    );
    expect(find.byIcon(Icons.event_outlined), findsOneWidget, reason: '图标回到"没设"');
  });

  testWidgets('设过日期的目标变成分类之后，那个日期仍然点得到、清得掉', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '后来长了下级');
    app.run(() => app.ws.updateProject(project.id, date: '2099-05-01'));
    // 它现在有下级了 = 分类。分类**不给设日期**，但设过的那个不能就此消失
    app.ws.createProject(title: '一个新下级', parentId: project.id);

    await openProject(tester, app, '后来长了下级');

    expect(
      find.byIcon(Icons.event_available_outlined),
      findsOneWidget,
      reason: '变成分类之后日期图标整个不见了，那个日期就再也点不到、清不掉（实机反馈的根因之一）',
    );

    await tester.tap(find.byIcon(Icons.event_available_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除日期'));
    await tester.pumpAndSettle();

    expect(app.ws.findProject(project.id)!.date, isNull);
    expect(
      find.byIcon(Icons.event_available_outlined),
      findsNothing,
      reason: '清掉之后分类就不该再画这个图标（分类本来就没有日期）',
    );
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
    // 分类不装灵感：这一页没有灵感区
    expect(find.textContaining('待处理灵感'), findsNothing);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    // 分类现在**也有**导出入口：导的是"分类 + 所有下级目标"（实机反馈：
    // 分类界面应当可以统一导出其子项目的所有条目），名字与目标那条区分开
    expect(find.text('导出分类说明…'), findsOneWidget);
    expect(find.text('导出交接说明…'), findsNothing);
    expect(find.text('移到其它分类'), findsOneWidget, reason: '分类的动作仍在菜单里');
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  });

  testWidgets('分类可以统一导出：预览页里能看到分类自己和每个下级目标', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    app.run(() => app.ws.updateProject(category.id, purpose: '这一类都为了把 v1 发出去'));
    final targetA = app.ws.createProject(title: '发布 v1', parentId: category.id);
    final targetB = app.ws.createProject(title: '复盘', parentId: category.id);
    app.run(() => app.ws.addProjectItem(targetA.id, '写好发布说明'));
    app.run(() => app.ws.updateProject(targetB.id, purpose: '把这次的口子记下来'));
    // 归档掉一个下级：**它不该进这份说明**（分类里装的是还活着的目标）
    final archived = app.ws.createProject(title: '归档掉的目标', parentId: category.id);
    app.run(() => app.ws.setProjectArchived(archived.id, true));

    await openProject(tester, app, '工作');
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出分类说明…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('交接说明 · 工作'), findsOneWidget);
    final preview = tester.widget<TextField>(find.byType(TextField));
    final text = preview.controller!.text;
    expect(text, contains('# 分类：工作'));
    expect(text, contains('这一类都为了把 v1 发出去'));
    expect(text, contains('# 项目：发布 v1'));
    expect(text, contains('写好发布说明'));
    expect(text, contains('# 项目：复盘'));
    expect(
      text,
      isNot(contains('归档掉的目标')),
      reason: '已归档的下级不进分类说明 —— 它已经不在这件事里了',
    );
  });

  testWidgets('分类的下级可以展开：展开后能看到并勾选它的实现清单', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    final target = app.ws.createProject(title: '发布 v1', parentId: category.id);
    app.run(() => app.ws.addProjectItem(target.id, '写好发布说明'));

    await openProject(tester, app, '工作');

    // 收起时只给进度，不给清单内容 —— 一行下级不该把整页撑开
    expect(find.text('写好发布说明'), findsNothing);

    // 行尾箭头只管展开 / 收起（点标题是进详情页，见下一条用例）
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();

    expect(find.text('写好发布说明'), findsOneWidget);
    // 展开区**没有**「添加条目」与「打开这个目标」这两项（2026-09-27 实机反馈）
    expect(find.text('添加条目'), findsNothing);
    expect(find.text('打开这个目标'), findsNothing);

    // 就地打勾：与项目页同一个口径（只是打勾，不参与任何判定）
    // 展开区用的是**圆形**勾选（实机反馈：确认框改成圆形），不是方形 `Checkbox`
    expect(find.byType(Checkbox), findsNothing, reason: '展开区不该再出现方形勾选框');
    await tester.tap(find.byIcon(Icons.radio_button_unchecked));
    await tester.pumpAndSettle();
    expect(app.ws.findProject(target.id)!.items.single.done, isTrue);
    expect(app.ws.findProject(target.id)!.itemsDoneCount, 1);
    expect(find.byIcon(Icons.check_circle), findsOneWidget, reason: '勾上之后换成实心圆');
    expect(find.text('已完成'), findsNothing, reason: '项目没有完成态（Q1）');

    // 勾完不会自己收起来（展开状态挂在 State 上）
    expect(find.text('写好发布说明'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('写好发布说明'), findsNothing);
    expect(app.ws.findProject(target.id)!.items.single.done, isTrue, reason: '收起不会把勾去掉');
  });

  testWidgets('点下级那一行的标题进的是下级自己的详情页', (tester) async {
    final app = await boot();
    final category = app.ws.createProject(title: '工作');
    final target = app.ws.createProject(title: '发布 v1', parentId: category.id);
    app.run(() => app.ws.updateProject(target.id, purpose: '发布页还差一个回滚口径'));

    await openProject(tester, app, '工作');
    // 展开区里那个「打开这个目标」按钮已经按要求去掉，进下级的出路是点标题
    await tester.tap(find.text('发布 v1'));
    await tester.pumpAndSettle();

    expect(find.text('有什么问题 / 思路'), findsOneWidget);
    expect(find.text('发布页还差一个回滚口径'), findsOneWidget);
  });

  testWidgets('下级还是分类时递归展开：一直能看到最底层目标的条目', (tester) async {
    final app = await boot();
    // 三层：工作（分类）→ 发布 v1（分类）→ 前端（目标，带条目）
    final top = app.ws.createProject(title: '工作');
    final mid = app.ws.createProject(title: '发布 v1', parentId: top.id);
    final leaf = app.ws.createProject(title: '前端', parentId: mid.id);
    app.run(() => app.ws.addProjectItem(leaf.id, '冻结契约'));

    await openProject(tester, app, '工作');

    // 收起时什么都看不到
    expect(find.text('前端'), findsNothing);
    expect(find.text('冻结契约'), findsNothing);

    // 展开「发布 v1」：它本身也是分类，所以露出的是下一层
    // （按 tooltip 找开关，不用按图标 —— AppBar 的返回箭头是同一个图标码）
    await tester.tap(find.byTooltip('展开').first);
    await tester.pumpAndSettle();
    expect(find.text('前端'), findsOneWidget, reason: '下级是分类时，接着往下展');
    expect(find.text('冻结契约'), findsNothing, reason: '再下一层还没展开');

    // 再展开「前端」：它是叶子，直接给出它的条目
    await tester.tap(find.byTooltip('展开').last);
    await tester.pumpAndSettle();
    expect(find.text('冻结契约'), findsOneWidget, reason: '一路递归到最底层目标的条目');
    expect(
      find.byTooltip('展开'),
      findsNothing,
      reason: '叶子不再给箭头 —— 点了没反应比没有箭头更糟',
    );
  });

  testWidgets('递归展开：底层目标没有条目时给一句，而不是留白', (tester) async {
    final app = await boot();
    final top = app.ws.createProject(title: '工作');
    final mid = app.ws.createProject(title: '发布 v1', parentId: top.id);
    app.ws.createProject(title: '空目标', parentId: mid.id);

    await openProject(tester, app, '工作');
    await tester.tap(find.byTooltip('展开').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开').last);
    await tester.pumpAndSettle();

    expect(find.text('空目标'), findsOneWidget);
    expect(find.text('还没有条目'), findsOneWidget);
  });

  testWidgets('待处理灵感可以长按多选，批量丢弃与灵感页同一套口径', (tester) async {
    final app = await boot();
    final project = app.ws.createProject(title: '目标甲');
    app.run(() => app.ws.captureInspiration('灵感甲', projectId: project.id));
    app.run(() => app.ws.captureInspiration('灵感乙', projectId: project.id));

    await openProject(tester, app, '目标甲');
    await tester.scrollUntilVisible(
      find.text('灵感甲'),
      150,
      scrollable: verticalScrollable,
    );
    await tester.pumpAndSettle();

    // 长按进多选（与灵感页同一套习惯）
    await tester.longPress(find.text('灵感甲'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);
    expect(find.byTooltip('退出多选'), findsOneWidget, reason: '动作条是共用的那一枚');

    // 多选态下点条目 = 切换选中（不再进合并编辑器）
    await tester.tap(find.text('灵感乙'));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.byTooltip('丢弃'));
    await tester.pumpAndSettle();

    expect(
      app.ws.liveInspirations.where((i) => i.isPending).length,
      0,
      reason: '批量丢弃与灵感页走同一批 Workspace 方法',
    );
    expect(app.ws.archiveZone.discardedInspirations.length, 2);
    expect(find.text('已选 2 条'), findsNothing, reason: '动作完要退出多选');
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
