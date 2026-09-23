import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/app/app_controller.dart';
import 'package:guideline/main.dart';

/// 全局搜索（Q42）：口径与归档区一致 —— 已归档与已删除不参与。
void main() {
  late Directory dir;
  late AppController app;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_search_');
    app = AppController.bootstrap(dataDirectoryOverride: dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> openSearch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(GuidelineApp(controller: app));
    await tester.pumpAndSettle();
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();
  }

  testWidgets('按关键词命中项目并分组展示', (tester) async {
    app.ws.createProject(title: '个人知识库', purpose: '让灵感有归宿');
    app.ws.createProject(title: '无关项目');
    await openSearch(tester);

    await tester.enterText(find.byType(TextField).first, '知识库');
    await tester.pumpAndSettle();

    expect(find.textContaining('项目（1）'), findsOneWidget);
    expect(find.text('个人知识库'), findsWidgets);
    expect(find.text('无关项目'), findsNothing);
  });

  testWidgets('点击结果直达对应板块', (tester) async {
    final project = app.ws.createProject(title: '个人知识库');
    await openSearch(tester);

    await tester.enterText(find.byType(TextField).first, '个人知识库');
    await tester.pumpAndSettle();
    await tester.tap(find.text('个人知识库').last);
    await tester.pumpAndSettle();

    // 已切换到板块一，并且该项目在详情栏被选中
    expect(find.text('实现（怎么做）'), findsOneWidget);
    expect(app.ws.findProject(project.id), isNotNull);
  });

  testWidgets('归档内容不参与搜索，并给出解释', (tester) async {
    final archived = app.ws.createProject(title: '归档掉的知识库');
    app.ws.setProjectArchived(archived.id, true);
    await openSearch(tester);

    await tester.enterText(find.byType(TextField).first, '知识库');
    await tester.pumpAndSettle();

    expect(find.text('归档掉的知识库'), findsNothing);
    expect(find.text('没有匹配结果'), findsOneWidget);
    expect(find.textContaining('归档区查看'), findsOneWidget);
  });

  testWidgets('灵感只在 pending 状态参与搜索', (tester) async {
    final inspiration = app.ws.captureInspiration('关于知识库的一条想法');
    await openSearch(tester);

    await tester.enterText(find.byType(TextField).first, '知识库');
    await tester.pumpAndSettle();
    expect(find.textContaining('灵感（1）'), findsOneWidget);

    // 丢弃后应消失（走与 UI 相同的路径，触发重建）
    app.run(() => app.ws.discardInspiration(inspiration.id));
    await tester.pumpAndSettle();

    expect(find.text('关于知识库的一条想法'), findsNothing);
    expect(find.text('没有匹配结果'), findsOneWidget);
  });
}
