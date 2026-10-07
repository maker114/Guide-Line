import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/color_picker.dart';
import 'package:guideline/ui/common/inline_editor.dart';
import 'package:guideline/ui/projects/project_detail_page.dart';
import 'package:guideline/ui/projects/project_tab.dart';

/// 项目页列表的几件事（实机反馈 + Q1/Q2 + 2026-09-26 行首标识第二版）：
///   · **标题前是标识**：分类行与根目标行是一根**竖色条**，子行是**自己的色点**，
///     一行里只出现一个记号；
///   · **没有展开箭头**、**也不点色条展开**（点色条就是点这一行）——
///     展开 / 收起收进行尾的 ⋮ 菜单，且只有"有下级"的分类行才有这一项；
///   · **文本整体左移**：根行左内边距 16dp、子行 28dp；分类行与根目标行的
///     标题起始竖线一致，子行整齐地再缩进一档；
///   · **没设色的项目用灰条补齐**（色条）/ **灰空心圆**（色点），不留空位；
///   · **根目标行没有下级**：菜单里没有展开 / 收起那一项；
///   · **项目状态图标与完成删除线都不再出现**（项目没有完成态，Q1）；
///   · **分类行只显示 名字 + 汇总**（Q2）：目的 / 日期一律不上树。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_project_tree');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// 开 App 并切到「项目」页（外壳默认停在灵感页）。
  ///
  /// 三行根项目 + 两条子目标，颜色都**显式设定**：色条 / 色点要能一眼对上是
  /// 哪一个项目的颜色，不能靠"新建时自动分配"的运气。
  Future<AppController> boot(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final category = app.ws.createProject(title: '带子项目的');
    final childA = app.ws.createProject(title: '子项目', parentId: category.id);
    final childB = app.ws.createProject(title: '子项目乙', parentId: category.id);
    final colored = app.ws.createProject(title: '有颜色没子项目');
    final plain = app.ws.createProject(title: '没颜色没子项目');
    app.run(() {
      app.ws.setProjectColor(category.id, '#336699');
      app.ws.setProjectColor(childA.id, '#cc3300');
      app.ws.setProjectColor(childB.id, null);
      app.ws.setProjectColor(colored.id, '#009966');
      app.ws.setProjectColor(plain.id, null);
    });

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AppBottomNav),
        matching: find.text('项目'),
      ),
    );
    await tester.pumpAndSettle();
    return app;
  }

  Finder inTab(Finder matching) =>
      find.descendant(of: find.byType(ProjectTab), matching: matching);

  /// 某一行的整体（`ListTile`）—— 用来量"标题相对行左缘的内边距"。
  Finder rowOf(String projectId) => inTab(find.byKey(projectRowKey(projectId)));

  /// 某一行**标题前那根色条**（只有根行挂这个 Key；子行标题前是色点）。
  Finder barOf(String projectId) =>
      inTab(find.byKey(projectColorBarKey(projectId)));

  /// 某一行的色点（子行才有）。
  Finder markerOf(String projectId) => find.descendant(
        of: rowOf(projectId),
        matching: find.byType(ProjectMarker),
      );

  /// 某一行的 ⋮ 菜单按钮。
  Finder menuButtonOf(String projectId) => find.descendant(
        of: rowOf(projectId),
        matching: find.byType(PopupMenuButton<String>),
      );

  /// 打开某一行的 ⋮ 菜单。
  Future<void> openMenu(WidgetTester tester, String projectId) async {
    await tester.tap(menuButtonOf(projectId));
    await tester.pumpAndSettle();
  }

  /// 关掉 ⋮ 菜单（点菜单外面的遮罩）。
  Future<void> closeMenu(WidgetTester tester) async {
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
  }

  /// 色条的渲染颜色（色条本体是共用控件 `ProjectColorBar`，颜色在它的
  /// `Container` 上）。
  Color? barColorOf(WidgetTester tester, String projectId) {
    final widget = tester.widget<Container>(
      find.descendant(of: barOf(projectId), matching: find.byType(Container)),
    );
    return (widget.decoration as BoxDecoration?)?.color;
  }

  testWidgets('分类行与根目标行：标题前是竖色条，且没有展开箭头', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );
    final colored = app.ws.liveProjects.firstWhere(
      (p) => p.title == '有颜色没子项目',
    );

    expect(
      inTab(find.byIcon(Icons.chevron_right)),
      findsNothing,
      reason: '展开箭头已经拿掉，分类行不再有箭头',
    );
    expect(
      find.descendant(
        of: rowOf(category.id),
        matching: find.byType(AnimatedRotation),
      ),
      findsNothing,
      reason: '连"转过去"的那套控件也不该留',
    );

    // 分类行：标题左侧紧挨一条**自己的颜色**的竖条
    final bar = tester.getRect(barOf(category.id));
    final row = tester.getRect(rowOf(category.id));
    final title = tester.getRect(find.text('带子项目的'));
    expect(barColorOf(tester, category.id), colorOfHex('#336699'));
    expect(
      bar.left - row.left,
      closeTo(16, 0.5),
      reason: '色条在标题前（行左内边距 16dp），不再占最左那一整列',
    );
    expect(
      title.left - bar.right,
      closeTo(6, 0.5),
      reason: '色条与标题之间 6dp，紧挨着但不贴死',
    );
    expect(
      bar.height,
      greaterThan(bar.width),
      reason: '标题前立的是「竖」条',
    );

    // 根目标行同档：自己的颜色、同样的内边距、同一条标题竖线
    expect(barColorOf(tester, colored.id), colorOfHex('#009966'));
    expect(
      tester.getRect(barOf(colored.id)).left -
          tester.getRect(rowOf(colored.id)).left,
      closeTo(16, 0.5),
    );
    expect(
      tester.getRect(find.text('有颜色没子项目')).left,
      closeTo(title.left, 0.5),
      reason: '分类行与根目标行的标题起始竖线一致',
    );

    // 分类行里没有色点（一个记号只出现一次）
    expect(markerOf(category.id), findsNothing);
  });

  testWidgets('没设标识色的根行：标题前用灰条补齐，而不是留空', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere(
      (p) => p.title == '没颜色没子项目',
    );
    // 对比色取**另一个根层目标**（不是分类）：两边都是"标题前那一根色条"
    final colored = app.ws.liveProjects.firstWhere(
      (p) => p.title == '有颜色没子项目',
    );

    final scheme = Theme.of(
      tester.element(find.text('没颜色没子项目')),
    ).colorScheme;
    expect(barColorOf(tester, plain.id), scheme.outlineVariant, reason: '没设色 = 中性灰条');
    expect(
      barColorOf(tester, colored.id),
      isNot(scheme.outlineVariant),
      reason: '设了色就是那个色',
    );

    // 两条色条同宽同位（标题才会对齐）
    expect(
      tester.getRect(barOf(plain.id)).width,
      tester.getRect(barOf(colored.id)).width,
    );
    expect(
      tester.getRect(barOf(plain.id)).left -
          tester.getRect(rowOf(plain.id)).left,
      closeTo(16, 0.5),
    );
  });

  testWidgets('子行：标题前是子项自己的颜色圆点（没设色 = 灰空心圆），不画色条', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );
    final childA = app.ws.liveProjects.firstWhere((p) => p.title == '子项目');
    final childB = app.ws.liveProjects.firstWhere((p) => p.title == '子项目乙');

    // 子行不画色条：标题前只有自己那个圆点
    expect(barOf(childA.id), findsNothing, reason: '子行不挂色条的 Key');
    expect(
      find.descendant(
        of: rowOf(childA.id),
        matching: find.byType(ProjectColorBar),
      ),
      findsNothing,
      reason: '子行标题前是色点，不是色条',
    );

    final marker = tester.widget<ProjectMarker>(markerOf(childA.id));
    expect(marker.color, '#cc3300', reason: '圆点用**子项自己**的颜色');
    expect(
      marker.color,
      isNot(category.color),
      reason: '不是上级分类的颜色（竖轨那套已经取消）',
    );

    // 圆点在标题左侧那 18dp 的槽里，且是正圆
    final dot = tester.getRect(markerOf(childA.id));
    final dotRow = tester.getRect(rowOf(childA.id));
    expect(dot.left - dotRow.left, closeTo(28, 0.5), reason: '子行左内边距 28dp，色点槽从这里起');
    expect(dot.right, lessThan(tester.getRect(find.text('子项目')).left));
    expect(dot.width, closeTo(dot.height, 0.5), reason: '色点是正圆');

    // 没设色的子项：灰色空心圆（既有行为，别丢）
    final plainMarker = tester.widget<ProjectMarker>(markerOf(childB.id));
    expect(plainMarker.color, isNull);
    final plainBox = tester.widget<Container>(
      find.descendant(of: markerOf(childB.id), matching: find.byType(Container)),
    );
    final plainDecoration = plainBox.decoration! as BoxDecoration;
    expect(plainDecoration.color, isNull, reason: '没设色 = 空心');
    expect(plainDecoration.border, isNotNull, reason: '没设色 = 有那圈灰描边');
  });

  testWidgets('色条不可点：点它不改变展开状态（它不是展开控件）', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );
    expect(app.isExpanded(category.id), isTrue, reason: '这一组默认展开');

    await tester.tap(barOf(category.id));
    await tester.pumpAndSettle();

    expect(
      app.isExpanded(category.id),
      isTrue,
      reason: '点色条不再展开 / 收起（那一版已经回退）',
    );
    expect(
      find.byType(ProjectDetailPage),
      findsOneWidget,
      reason: '色条就在标题前、属于这一行：点它就是点这一行（打开详情），不是另一个控件',
    );
  });

  testWidgets('⋮ 菜单：展开态给「收起下级」，点了真的收起', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );
    expect(app.isExpanded(category.id), isTrue);
    expect(inTab(find.text('子项目')), findsOneWidget);

    await openMenu(tester, category.id);
    expect(find.text('收起下级'), findsOneWidget, reason: '展开态给「收起下级」');
    expect(find.text('展开下级'), findsNothing);
    // 原有项一个都不能少
    for (final label in <String>['重命名', '移动到…', '归档', '删除']) {
      expect(find.text(label), findsOneWidget, reason: '原有菜单项「$label」要留着');
    }

    await tester.tap(find.text('收起下级'));
    await tester.pumpAndSettle();

    expect(app.isExpanded(category.id), isFalse, reason: '菜单里点了就真的收起');
    expect(inTab(find.text('子项目')), findsNothing, reason: '收起后子行不画了');
    expect(inTab(find.text('子项目乙')), findsNothing);
    expect(
      inTab(find.text('带子项目的')),
      findsOneWidget,
      reason: '收起只影响下级，分类自己还在（也没顺手打开详情页）',
    );
    expect(find.byType(ProjectDetailPage), findsNothing);
  });

  testWidgets('⋮ 菜单：收起态给「展开下级」，点了真的展开', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );
    app.setExpanded(category.id, expanded: false);
    await tester.pumpAndSettle();
    expect(inTab(find.text('子项目')), findsNothing, reason: '先把它收起来');

    await openMenu(tester, category.id);
    expect(find.text('展开下级'), findsOneWidget, reason: '收起态给「展开下级」');
    expect(find.text('收起下级'), findsNothing);

    await tester.tap(find.text('展开下级'));
    await tester.pumpAndSettle();

    expect(app.isExpanded(category.id), isTrue, reason: '菜单里点了就真的展开');
    expect(inTab(find.text('子项目')), findsOneWidget);
    expect(inTab(find.text('子项目乙')), findsOneWidget);
  });

  testWidgets('没有下级的行：⋮ 菜单里没有展开 / 收起这一项', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere(
      (p) => p.title == '没颜色没子项目',
    );
    expect(
      app.ws.childProjectsOf(plain.id),
      isEmpty,
      reason: '这一条确实没有下级',
    );

    await openMenu(tester, plain.id);
    expect(find.text('展开下级'), findsNothing, reason: '没有下级就没有这一项');
    expect(find.text('收起下级'), findsNothing);
    for (final label in <String>['重命名', '移动到…', '归档', '删除']) {
      expect(find.text(label), findsOneWidget, reason: '原有菜单项「$label」要留着');
    }
    await closeMenu(tester);
  });

  testWidgets('各行标题仍在同一条竖线上：根行 26dp、子行整齐地再缩进一档', (tester) async {
    final app = await boot(tester);
    final child = app.ws.liveProjects.firstWhere((p) => p.title == '子项目');
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );

    // 三行根项目（分类 + 有色目标 + 无色目标）的标题必须对齐
    final lefts = <String, double>{
      '带子项目的': tester.getRect(find.text('带子项目的')).left,
      '有颜色没子项目': tester.getRect(find.text('有颜色没子项目')).left,
      '没颜色没子项目': tester.getRect(find.text('没颜色没子项目')).left,
    };
    for (final entry in lefts.entries) {
      expect(
        entry.value,
        closeTo(lefts['带子项目的']!, 0.5),
        reason: '「${entry.key}」的标题没和第一条对齐（$lefts）',
      );
    }

    // 根行：16dp 左内边距 + 4dp 色条 + 6dp 间距 = 标题左缘 26dp
    final rootRow = tester.getRect(rowOf(category.id));
    final rootLeft = lefts['带子项目的']! - rootRow.left;
    expect(
      rootLeft,
      closeTo(26, 0.5),
      reason: '根行标题左缘 = 16 + 4 + 6 = 26（行左缘 12，屏上 38；上一版是 60）',
    );

    // 子行：28dp 左内边距 + 18dp 色点槽 = 标题左缘 46dp，比根行再缩进一档
    final childRow = tester.getRect(rowOf(child.id));
    final childLeft = tester.getRect(find.text('子项目')).left - childRow.left;
    expect(
      childLeft,
      closeTo(46, 0.5),
      reason: '子行标题左缘 = 28 + 18 = 46（屏上 58）',
    );
    expect(
      childLeft - rootLeft,
      closeTo(20, 0.5),
      reason: '子行整齐地再缩进一档',
    );
  });

  testWidgets('没有副标题的项目：标题竖直居中，不留一截空占位', (tester) async {
    final app = await boot(tester);
    final _ = app.ws.liveProjects.firstWhere(
      (p) => p.title == '没颜色没子项目',
    );

    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('没颜色没子项目'),
        matching: find.byType(ListTile),
      ),
    );
    expect(tile.subtitle, isNull, reason: '没内容就该没有副标题，而不是空占位');

    // 标题在行内居中（实机反馈：原来头重脚轻）
    final row = tester.getRect(
      find.ancestor(
        of: find.text('没颜色没子项目'),
        matching: find.byType(ListTile),
      ),
    );
    final text = tester.getRect(find.text('没颜色没子项目'));
    expect(
      (text.center.dy - row.center.dy).abs(),
      lessThan(2),
      reason: '标题该在这一行里竖直居中（行 ${row.height}）',
    );
  });

  testWidgets('根层的新建入口文案是「新建项目」，提示语也改（2026-10-07 用户口径）', (tester) async {
    final app = await boot(tester);

    // 根层：点它建出来的**永远是一个项目** —— "分类 / 目标"是它事后的角色判据
    // （有没有下级，见 `_ProjectRow.isCategory`），刚建出来的一行二者都还不是。
    // 所以这里用统称「项目」而不是「分类」。
    expect(inTab(find.text('新建项目')), findsOneWidget);
    expect(inTab(find.text('新建分类')), findsNothing, reason: '根层已改名');
    // 下级那一档的名字不动（分类下新建的仍是「目标」）—— 它不在这一页上
    expect(inTab(find.text('新建目标')), findsNothing);
    expect(inTab(find.text('目标名')), findsNothing);

    // 从**根层这个入口**建出来的是根项目：层级由 `parentId` 决定，
    // 与"它以后会不会被叫分类"无关。
    await tester.tap(find.text('新建项目'));
    await tester.pumpAndSettle();
    // 提示语在**展开之后**才是可见的：收起时那一行只画 label。
    expect(
      tester.widget<TextField>(find.byType(TextField).first).decoration?.hintText,
      '项目名',
      reason: '提示语跟着 label 一起改',
    );
    final focused = find.byWidgetPredicate(
      (Widget w) => w is TextField && (w.focusNode?.hasFocus ?? false),
      description: '当前获得焦点的输入框',
    );
    await tester.enterText(focused, '从根层建的');
    await tester.tap(
      find.descendant(
        of: find.ancestor(of: focused, matching: find.byType(InlineComposer)),
        matching: find.byTooltip('添加'),
      ),
    );
    await tester.pumpAndSettle();

    final created =
        app.ws.liveProjects.firstWhere((p) => p.title == '从根层建的');
    expect(created.parentId, isNull, reason: '根层入口建出来的是根项目');
  });

  testWidgets('分类行只显示 名字 + 汇总：目的与日期都不上树（Q2）', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere((p) => p.title == '带子项目的');
    // 故意给分类塞上"目标才有"的内容；再给下级挂一条清单，让汇总算得出来
    app.run(() => app.ws.updateProject(
          category.id,
          purpose: '分类不该显示这句',
          date: '2026-12-31',
        ));
    final child = app.ws.liveProjects.firstWhere((p) => p.title == '子项目');
    app.run(() => app.ws.addProjectItem(child.id, '目标的一条'));
    await tester.pumpAndSettle();

    // 汇总：含 N 个目标 + 这些目标的清单勾选进度
    expect(inTab(find.text('含 2 个目标')), findsOneWidget);
    expect(inTab(find.text('清单 0/1 已完成')), findsOneWidget);

    // 分类行上没有目的、也没有日期
    expect(inTab(find.textContaining('分类不该显示这句')), findsNothing);
    expect(inTab(find.textContaining('2026-12-31')), findsNothing);

    // 目标行（下级）照旧
    expect(inTab(find.text('子项目')), findsOneWidget);
  });
}
