import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/ui/common/project_picker.dart';

/// 项目选择器的两类用途（Q2）：
///   · **灵感侧**（`requireTarget: true`，默认）：落点只能是**目标** ——
///     分类只回答"归哪一类"，点它要给一句明确提示，而不是静默生效；
///   · **移动侧**（`requireTarget: false`）：把项目移进一个分类正是"建分类"的做法，
///     分类照常可选。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_picker_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final category = app.ws.createProject(title: '工作');
    app.ws.createProject(title: '发布 v1', parentId: category.id);
    app.ws.createProject(title: '生活');
    return app;
  }

  /// 开一次选择器，返回它 pop 出来的值（没 pop 就是 `null`）。
  Future<String?> openPicker(
    WidgetTester tester,
    AppController app, {
    required bool requireTarget,
    bool fullName = true,
  }) async {
    String? picked;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                picked = await pickProject(
                  context,
                  app,
                  title: '选一个项目',
                  requireTarget: requireTarget,
                  fullName: fullName,
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    return picked;
  }

  testWidgets('灵感侧：分类标出来，点它给提示并且不选中', (tester) async {
    final app = await boot();
    await openPicker(tester, app, requireTarget: true);

    // 分类行明说"这里不装灵感"
    expect(find.text('分类，这里不装灵感'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('工作 · 发布 v1'), findsOneWidget, reason: '灵感侧给全名');

    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();

    expect(find.text(categoryNotForInspiration), findsOneWidget, reason: '点分类要给一句解释');
    expect(find.byType(ListTile), findsWidgets, reason: '选择器不该被关掉：还能接着选目标');

    // 选目标照常 pop 出去
    await tester.tap(find.text('工作 · 发布 v1'));
    await tester.pumpAndSettle();
    expect(find.text('选一个项目'), findsNothing, reason: '选中目标后选择器关闭');
  });

  testWidgets('全名与缩进一起给：两层写「分类 · 项目」，三层一路写到根', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final work = app.ws.createProject(title: '工作');
    final release = app.ws.createProject(title: '发布 v1', parentId: work.id);
    app.ws.createProject(title: '前端', parentId: release.id);

    await openPicker(tester, app, requireTarget: false);

    expect(find.text('工作 · 发布 v1'), findsOneWidget);
    expect(
      find.text('工作 · 发布 v1 · 前端'),
      findsOneWidget,
      reason: '三层要一路写到根 —— 只写上一级仍然分不出是谁',
    );
    // 缩进照旧留着当辅助线索：越深的行左内边距越大
    final twoLevel = tester.getTopLeft(find.text('工作 · 发布 v1')).dx;
    final threeLevel = tester.getTopLeft(find.text('工作 · 发布 v1 · 前端')).dx;
    expect(threeLevel, greaterThan(twoLevel));
  });

  testWidgets('全名可以关掉（移动侧那种自己会写层级的场景）', (tester) async {
    final app = await boot();
    await openPicker(tester, app, requireTarget: false, fullName: false);

    expect(find.text('发布 v1'), findsOneWidget);
    expect(find.text('工作 · 发布 v1'), findsNothing);
  });

  testWidgets('移动侧：分类照常可选（移进分类 = 建分类）', (tester) async {
    final app = await boot();
    await openPicker(tester, app, requireTarget: false);

    expect(find.text('分类，这里不装灵感'), findsNothing, reason: '移动侧不拦分类');

    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();

    expect(find.text(categoryNotForInspiration), findsNothing);
    expect(find.text('选一个项目'), findsNothing, reason: '选中分类后选择器关闭');
  });
}
