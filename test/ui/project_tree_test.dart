import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/color_picker.dart';
import 'package:guideline/ui/projects/project_tab.dart';

/// 项目页列表的几件事（实机反馈 + Q1/Q2 + 2026-09-26 行首标识改版）：
///   · **分类行没有展开箭头**：最左那根竖色条**本身就是**展开 / 收起控件；
///   · **热区够大**：条只有 4dp 宽，点在条右侧十几 dp 处也要能展开；
///   · **展开后是竖轨**：分类那一段向下延伸，每一行各画自己那一段、同色、首尾相接；
///   · **子行保留自己的颜色圆点**（画在竖轨右侧约 14dp 处），没设色仍是灰空心圆；
///   · **文本整体左移**，标题仍在同一条竖线上，且与竖轨之间留 ≥8dp；
///   · **根目标的竖条不可点、不延伸**；
///   · 展开 / 收起后子行的出现与消失；
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
  /// 三行根项目 + 两条子目标，颜色都**显式设定**：竖轨 / 短条 / 圆点的颜色
  /// 要能一眼对上是哪一个项目的颜色，不能靠"新建时自动分配"的运气。
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

  /// 某一行的标识槽里那条竖线（短色条 / 轨段都用同一个 Key）。
  Finder railOf(String projectId) =>
      inTab(find.byKey(projectColorBarKey(projectId)));

  /// 竖线的渲染颜色（色条本体是共用控件 `ProjectColorBar`，颜色在它的
  /// `Container` 上）。
  Color? railColorOf(WidgetTester tester, String projectId) {
    final widget = tester.widget<Container>(
      find.descendant(of: railOf(projectId), matching: find.byType(Container)),
    );
    return (widget.decoration as BoxDecoration?)?.color;
  }

  testWidgets('分类行没有展开箭头，最左就是那根竖色条', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );

    expect(
      inTab(find.byIcon(Icons.chevron_right)),
      findsNothing,
      reason: '展开箭头已经拿掉，分类行不再有箭头',
    );
    expect(
      find.descendant(
        of: inTab(find.byKey(projectRowKey(category.id))),
        matching: find.byType(AnimatedRotation),
      ),
      findsNothing,
      reason: '连"转过去"的那套控件也不该留',
    );

    final rail = tester.getRect(railOf(category.id));
    final row = tester.getRect(inTab(find.byKey(projectRowKey(category.id))));
    final title = tester.getRect(find.text('带子项目的'));
    expect(
      rail.left,
      closeTo(row.left, 0.5),
      reason: '竖条贴在这一行的最左（$rail vs $row）',
    );
    expect(
      title.left - rail.right,
      greaterThanOrEqualTo(8),
      reason: '标题与竖条之间要留 ≥8dp，不能贴在一起',
    );
  });

  testWidgets('点最左的竖色条就能展开 / 再点就能收起（热区比 4dp 的条宽得多）', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );

    // 分类默认是展开的（`UiPrefs` 默认 true），两条子行都在
    expect(inTab(find.text('子项目')), findsOneWidget);
    expect(inTab(find.text('子项目乙')), findsOneWidget);

    final rail = tester.getRect(railOf(category.id));
    // **条本身只有 4dp 宽**：故意点在条右侧 12dp 处（条外面、槽位里面），
    // 点不中就说明热区没做出来。
    await tester.tapAt(Offset(rail.right + 12, rail.center.dy));
    await tester.pumpAndSettle();

    expect(app.isExpanded(category.id), isFalse, reason: '点色条 = 收起');
    expect(
      inTab(find.text('子项目')),
      findsNothing,
      reason: '收起后子行不画了',
    );
    expect(inTab(find.text('子项目乙')), findsNothing);
    // 热区只做"展开 / 收起"这一件事：不该顺手把详情页推上来
    expect(
      inTab(find.text('带子项目的')),
      findsOneWidget,
      reason: '点色条不该打开详情页（那一槽是展开控件，不是整行的点击）',
    );
    expect(
      tester.getRect(railOf(category.id)).height,
      closeTo(18, 0.5),
      reason: '收起时只剩分类自己那一段短色条，不往下延伸',
    );

    // 再点一次（这次正对竖条中心）就能展开
    await tester.tap(railOf(category.id));
    await tester.pumpAndSettle();
    expect(app.isExpanded(category.id), isTrue, reason: '再点 = 展开');
    expect(inTab(find.text('子项目')), findsOneWidget);
    expect(inTab(find.text('子项目乙')), findsOneWidget);
  });

  testWidgets('展开后是竖轨：分类行与每个子行各一段，同色且首尾相接', (tester) async {
    final app = await boot(tester);
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );
    expect(app.isExpanded(category.id), isTrue, reason: '这一组是展开态');

    final rows = <String>['带子项目的', '子项目', '子项目乙'];
    final rects = <String, Rect>{
      for (final title in rows)
        title: tester.getRect(railOf(
          app.ws.liveProjects.firstWhere((p) => p.title == title).id,
        )),
    };

    // 每一行都有一段自己的竖线，而且它占满整行高（不是 18dp 的短条）
    for (final title in rows) {
      final id = app.ws.liveProjects
          .firstWhere((p) => p.title == title)
          .id;
      final row = tester.getRect(inTab(find.byKey(projectRowKey(id))));
      expect(
        rects[title]!.top,
        closeTo(row.top, 0.5),
        reason: '「$title」的轨段要从这一行顶端开始',
      );
      expect(
        rects[title]!.bottom,
        closeTo(row.bottom, 0.5),
        reason: '「$title」的轨段要画到这一行末端（否则接缝处会有缝）',
      );
      expect(rects[title]!.height, greaterThan(18));
    }

    // 一条轨一个颜色：分类自己的颜色（子目标不是自己开一条轨）
    final categoryColor = railColorOf(tester, category.id);
    expect(categoryColor, colorOfHex('#336699'));
    for (final title in <String>['子项目', '子项目乙']) {
      final id = app.ws.liveProjects
          .firstWhere((p) => p.title == title)
          .id;
      expect(
        railColorOf(tester, id),
        categoryColor,
        reason: '「$title」那一段接着分类的轨，颜色必须一样',
      );
    }

    // **连续**：相邻两段首尾相接（不是像素比对，是两段的上下边界重合）
    expect(
      rects['子项目']!.top,
      closeTo(rects['带子项目的']!.bottom, 0.5),
      reason: '分类那一段与第一条子行之间不能有缝',
    );
    expect(
      rects['子项目乙']!.top,
      closeTo(rects['子项目']!.bottom, 0.5),
      reason: '两条子行之间不能有缝',
    );
    // 整条轨 = 三行各自的段拼起来
    expect(
      rects['子项目乙']!.bottom - rects['带子项目的']!.top,
      closeTo(
        rects['带子项目的']!.height +
            rects['子项目']!.height +
            rects['子项目乙']!.height,
        0.5,
      ),
      reason: '这一组的竖轨应当正好覆盖分类行 + 全部可见子行',
    );
  });

  testWidgets('子行仍有自己的颜色标记：圆点画在竖轨右侧，用的是子项自己的颜色', (tester) async {
    final app = await boot(tester);
    final childA = app.ws.liveProjects.firstWhere((p) => p.title == '子项目');
    final childB = app.ws.liveProjects.firstWhere((p) => p.title == '子项目乙');

    Finder markerOf(String id) => find.descendant(
          of: inTab(find.byKey(projectRowKey(id))),
          matching: find.byType(ProjectMarker),
        );

    // 子目标的圆点：自己的颜色（不是分类的颜色、也不是竖轨的颜色）
    final marker = tester.widget<ProjectMarker>(markerOf(childA.id));
    expect(marker.color, '#cc3300', reason: '圆点用子项自己的颜色');
    expect(
      marker.color,
      isNot(railColorOf(tester, childA.id)),
      reason: '圆点的颜色与竖轨的颜色是两件事',
    );

    // 圆点在竖轨**右侧**（圆心离竖轨右缘约 14dp），不叠在轨上
    final dotRect = tester.getRect(markerOf(childA.id));
    final railRect = tester.getRect(railOf(childA.id));
    expect(dotRect.left, greaterThan(railRect.right));
    expect(
      dotRect.center.dx - railRect.right,
      closeTo(14, 0.5),
      reason: '口径：圆点画在竖轨右侧约 14dp 处',
    );
    expect(dotRect.width, closeTo(dotRect.height, 0.5), reason: '色点是正圆');

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

  testWidgets('文本左移后，各行的标题仍在同一条竖线上', (tester) async {
    final app = await boot(tester);
    final child = app.ws.liveProjects.firstWhere((p) => p.title == '子项目');

    // 三种不同的标识（分类的轨头、有色目标、无色目标）标题必须对齐
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

    // 子行也走同一档左内边距（改版前子行比根行更靠右 6dp），
    // 并且整列都比改版前更靠左：根行原来是 4+40+16=60、子行 36+18+12=66
    final childLeft = tester.getRect(find.text('子项目')).left;
    final childRow = tester.getRect(inTab(find.byKey(projectRowKey(child.id))));
    expect(
      childLeft,
      closeTo(lefts['带子项目的']!, 0.5),
      reason: '子行的标题与分类行的标题在同一条竖线上',
    );
    expect(
      childLeft - childRow.left,
      lessThan(60),
      reason: '左内边距要比改版前的 60 / 66 更小（文字整体左移）',
    );
  });

  testWidgets('根目标的竖条：存在、不延伸、点了也不改变展开状态', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere(
      (p) => p.title == '没颜色没子项目',
    );
    // 给它一个"如果会被点开就会变"的初始状态
    app.setExpanded(plain.id, expanded: false);
    await tester.pumpAndSettle();

    final rowFinder = inTab(find.byKey(projectRowKey(plain.id)));
    expect(
      find.descendant(of: rowFinder, matching: find.byType(ProjectMarker)),
      findsNothing,
      reason: '根目标没有上下级，槽里只有竖条、不该有色点',
    );
    // 槽位不接手势：点了照旧落到整行上（打开详情），不会变成展开控件
    expect(
      find.descendant(of: rowFinder, matching: find.byType(IgnorePointer)),
      findsWidgets,
      reason: '根目标的标识槽是 IgnorePointer，不接手势',
    );

    final rail = tester.getRect(railOf(plain.id));
    expect(rail.width, closeTo(4, 0.5));
    expect(
      rail.height,
      closeTo(18, 0.5),
      reason: '不延伸：只有一条短色条',
    );
    expect(
      railColorOf(tester, plain.id),
      Theme.of(tester.element(find.text('没颜色没子项目'))).colorScheme.outlineVariant,
      reason: '没设色用中性灰补齐，而不是留空',
    );

    await tester.tap(railOf(plain.id), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      app.isExpanded(plain.id),
      isFalse,
      reason: '点了竖条也不该改变展开状态（它不是展开控件）',
    );
  });

  testWidgets('没设标识色的目标：最左槽位用灰条补齐，而不是留空', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere(
      (p) => p.title == '没颜色没子项目',
    );
    // 对比色取**另一个根层目标**（不是分类）：两边都是"自己那一条短色条"
    final colored = app.ws.liveProjects.firstWhere(
      (p) => p.title == '有颜色没子项目',
    );

    final scheme = Theme.of(tester.element(find.text('没颜色没子项目'))).colorScheme;
    expect(railColorOf(tester, plain.id), scheme.outlineVariant, reason: '没设色 = 中性灰条');
    expect(
      railColorOf(tester, colored.id),
      isNot(scheme.outlineVariant),
      reason: '设了色就是那个色',
    );
    expect(colored.color, isNotNull);

    // 两条色条占同样的位置（宽度一致），标题才会对齐
    expect(
      tester.getRect(railOf(plain.id)).width,
      tester.getRect(railOf(colored.id)).width,
    );
  });

  testWidgets('一行的标识槽里只有一个记号：分类是竖条、子目标是色点（批 B 第 ① 项）', (tester) async {
    final app = await boot(tester);
    final target = app.ws.liveProjects.firstWhere(
      (p) => p.title == '有颜色没子项目',
    );
    final category = app.ws.liveProjects.firstWhere(
      (p) => p.title == '带子项目的',
    );
    final child = app.ws.liveProjects.firstWhere((p) => p.title == '子项目');

    // 根层目标：这一行里**恰好**一根色条，且它在标题左侧
    final bar = railOf(target.id);
    expect(bar, findsOneWidget);
    expect(
      find.descendant(
        of: inTab(find.byKey(projectRowKey(target.id))),
        matching: find.byType(ProjectColorBar),
      ),
      findsOneWidget,
      reason: '一个记号只出现一次：槽里那一根，标题前不该再有',
    );
    expect(
      tester.getRect(bar).right,
      lessThanOrEqualTo(tester.getRect(find.text('有颜色没子项目')).left),
      reason: '这根竖条要落在标题左侧的槽位里',
    );
    expect(
      tester.getRect(bar).height,
      greaterThan(tester.getRect(bar).width),
      reason: '槽位里放的是「竖」条',
    );

    // 分类行：也是竖条（展开时是轨头），没有箭头、没有色点
    expect(railOf(category.id), findsOneWidget);
    expect(
      find.descendant(
        of: inTab(find.byKey(projectRowKey(category.id))),
        matching: find.byType(ProjectMarker),
      ),
      findsNothing,
    );

    // 子目标：仍然是色点，不是色条
    expect(
      find.descendant(
        of: inTab(find.byKey(projectRowKey(child.id))),
        matching: find.byType(ProjectMarker),
      ),
      findsOneWidget,
    );
    expect(
      app.ws.childProjectsOf(category.id),
      isNotEmpty,
      reason: '分类确实是"有下级"的那一条',
    );
  });

  testWidgets('没有副标题的项目：标题竖直居中，不留一截空占位', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere(
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
    expect(plain.id, isNotEmpty);
  });

  testWidgets('根层的新建入口文案是「新建分类」（Q2：文案随层级走）', (tester) async {
    await boot(tester);

    expect(inTab(find.text('新建分类')), findsOneWidget);
    expect(inTab(find.text('新建项目')), findsNothing, reason: 'Q2 已改名');
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
