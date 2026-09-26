import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/common/color_picker.dart';
import 'package:guideline/ui/projects/project_tab.dart';

/// 项目页列表的几件事（实机反馈 + Q1/Q2 + 批 B 第 ① 项）：
///   · **左侧图标槽位对齐**：展开箭头是 `IconButton`、目标的色条是几 dp 宽的
///     `Container`、子目标的色点又是 `Icon` —— 各画各的会把标题挤到不同竖线上；
///   · **一个记号只出现一次**：分类放展开箭头、根层目标放竖色条、子目标放色点，
///     标题前不再另画一条色条；
///   · 展开 / 收起箭头**转过去**，不是换一个图标；
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
  Future<AppController> boot(WidgetTester tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    // 三行根项目，故意做成三种不同的 leading：
    final withChild = app.ws.createProject(title: '带子项目的');
    app.ws.createProject(title: '子项目', parentId: withChild.id);
    app.ws.createProject(title: '有颜色没子项目');
    final plain = app.ws.createProject(title: '没颜色没子项目');
    app.run(() => app.ws.setProjectColor(plain.id, null));

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

  testWidgets('三种不同的左侧图标，标题都在同一条竖线上', (tester) async {
    await boot(tester);

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
  });

  testWidgets('展开 / 收起箭头是转过去的，不是换图标', (tester) async {
    await boot(tester);

    // `AnimatedRotation` 内部就是 `RotationTransition`，读它的值即可
    double renderedTurns() => tester
        .widget<RotationTransition>(inTab(find.byType(RotationTransition)).first)
        .turns
        .value;

    expect(renderedTurns(), closeTo(0.25, 0.001), reason: '展开态：箭头朝下');

    await tester.tap(inTab(find.byIcon(Icons.chevron_right)).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));

    final middle = renderedTurns();
    expect(middle, greaterThan(0.02), reason: '途中应当正在转');
    expect(middle, lessThan(0.23), reason: '途中不该已经转到底');

    await tester.pumpAndSettle();
    expect(renderedTurns(), closeTo(0, 0.001), reason: '收起后箭头朝右');
  });

  testWidgets('没设标识色的目标：最左槽位用灰条补齐，而不是留空', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere((p) => p.color == null);
    // 对比色取**另一个根层目标**（不是分类）：分类那一槽放的是展开箭头
    final colored = app.ws.liveProjects
        .firstWhere((p) => p.title == '有颜色没子项目');

    Color? barColorOf(String projectId) {
      // 色条本体是共用控件 `ProjectColorBar`，渲染颜色在它里面的 `Container` 上
      final widget = tester.widget<Container>(
        find.descendant(
          of: find.byKey(projectColorBarKey(projectId)),
          matching: find.byType(Container),
        ),
      );
      return (widget.decoration as BoxDecoration?)?.color;
    }

    final scheme = Theme.of(tester.element(find.text('没颜色没子项目'))).colorScheme;
    expect(barColorOf(plain.id), scheme.outlineVariant, reason: '没设色 = 中性灰条');
    expect(barColorOf(colored.id), isNot(scheme.outlineVariant), reason: '设了色就是那个色');
    expect(colored.color, isNotNull);

    // 两条色条占同样的位置（宽度一致），标题才会对齐
    expect(
      tester.getSize(find.byKey(projectColorBarKey(plain.id))).width,
      tester.getSize(find.byKey(projectColorBarKey(colored.id))).width,
    );
  });

  testWidgets('根层目标的记号在最左槽位里，标题前不再重复一条色条（批 B 第 ① 项）', (tester) async {
    final app = await boot(tester);
    final target = app.ws.liveProjects
        .firstWhere((p) => p.title == '有颜色没子项目');
    final category = app.ws.liveProjects
        .firstWhere((p) => p.title == '带子项目的');

    Finder tileOf(String title) => find.ancestor(
          of: find.text(title),
          matching: find.byType(ListTile),
        );

    // 根层目标：这一行里**恰好**一根色条，且它在最左槽位（标题左边）
    final bar = find.byKey(projectColorBarKey(target.id));
    expect(bar, findsOneWidget);
    expect(
      find.descendant(
        of: tileOf('有颜色没子项目'),
        matching: find.byType(ProjectColorBar),
      ),
      findsOneWidget,
      reason: '一个记号只出现一次：色条只该在最左槽位里那一根，标题前不该再有',
    );
    final barRect = tester.getRect(bar);
    expect(
      barRect.right,
      lessThanOrEqualTo(tester.getRect(find.text('有颜色没子项目')).left),
      reason: '这根色条要落在标题左侧的槽位里',
    );
    expect(
      barRect.height,
      greaterThan(barRect.width),
      reason: '槽位里放的是「竖」条，不是标题前那一小段',
    );

    // 分类行的记号是展开箭头，不是色条（同一槽位只放一个记号）
    expect(
      find.descendant(
        of: tileOf('带子项目的'),
        matching: find.byType(ProjectColorBar),
      ),
      findsNothing,
      reason: '分类的记号是展开箭头，色条不该和它挤在同一个槽位',
    );
    expect(
      find.descendant(
        of: tileOf('带子项目的'),
        matching: find.byIcon(Icons.chevron_right),
      ),
      findsOneWidget,
    );

    // 子目标：仍然是色点，不是色条
    expect(
      find.descendant(of: tileOf('子项目'), matching: find.byType(ProjectMarker)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: tileOf('子项目'),
        matching: find.byType(ProjectColorBar),
      ),
      findsNothing,
    );
    expect(
      app.ws.childProjectsOf(category.id),
      isNotEmpty,
      reason: '分类确实是"有下级"的那一条',
    );
  });

  testWidgets('没有副标题的项目：标题竖直居中，不留一截空占位', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere((p) => p.color == null);

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

  testWidgets('分类行只显示 名字 + 展开箭头 + 汇总：目的与日期都不上树（Q2）', (tester) async {
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
    expect(inTab(find.text('含 1 个目标')), findsOneWidget);
    expect(inTab(find.text('清单 0/1 已完成')), findsOneWidget);

    // 分类行上没有目的、也没有日期
    expect(inTab(find.textContaining('分类不该显示这句')), findsNothing);
    expect(inTab(find.textContaining('2026-12-31')), findsNothing);

    // 目标行（下级）照旧
    expect(inTab(find.text('子项目')), findsOneWidget);
  });
}
