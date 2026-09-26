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
    expect(find.text('分类（不装灵感）'), findsOneWidget);
    expect(find.text('工作'), findsOneWidget);
    expect(find.text('发布 v1'), findsOneWidget);

    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();

    expect(find.text(categoryNotForInspiration), findsOneWidget, reason: '点分类要给一句解释');
    expect(find.byType(ListTile), findsWidgets, reason: '选择器不该被关掉：还能接着选目标');

    // 选目标照常 pop 出去
    await tester.tap(find.text('发布 v1'));
    await tester.pumpAndSettle();
    expect(find.text('选一个项目'), findsNothing, reason: '选中目标后选择器关闭');
  });

  testWidgets('移动侧：分类照常可选（移进分类 = 建分类）', (tester) async {
    final app = await boot();
    await openPicker(tester, app, requireTarget: false);

    expect(find.text('分类（不装灵感）'), findsNothing, reason: '移动侧不拦分类');

    await tester.tap(find.text('工作'));
    await tester.pumpAndSettle();

    expect(find.text(categoryNotForInspiration), findsNothing);
    expect(find.text('选一个项目'), findsNothing, reason: '选中分类后选择器关闭');
  });
}
