import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/app_shell.dart';
import 'package:guideline/ui/projects/project_tab.dart';

/// 项目页列表的两件事（实机反馈）：
///   · **左侧图标槽位对齐**：展开箭头是 `IconButton`、状态图标是 `Icon`、
///     标识色条有的有有的没有 —— 各画各的会把标题挤到不同竖线上；
///   · 展开 / 收起箭头**转过去**，不是换一个图标。
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

  testWidgets('没设标识色的项目：用灰条补齐那个位置，而不是留空', (tester) async {
    final app = await boot(tester);
    final plain = app.ws.liveProjects.firstWhere((p) => p.color == null);
    final colored = app.ws.liveProjects.firstWhere((p) => p.color != null);

    Color? barColorOf(String projectId) {
      final widget = tester.widget<Container>(
        find.byKey(projectColorBarKey(projectId)),
      );
      return (widget.decoration as BoxDecoration?)?.color;
    }

    final scheme = Theme.of(tester.element(find.text('没颜色没子项目'))).colorScheme;
    expect(barColorOf(plain.id), scheme.outlineVariant, reason: '没设色 = 中性灰条');
    expect(barColorOf(colored.id), isNot(scheme.outlineVariant), reason: '设了色就是那个色');

    // 两条色条占同样的位置（宽度一致），标题才会对齐
    expect(
      tester.getSize(find.byKey(projectColorBarKey(plain.id))).width,
      tester.getSize(find.byKey(projectColorBarKey(colored.id))).width,
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
}
