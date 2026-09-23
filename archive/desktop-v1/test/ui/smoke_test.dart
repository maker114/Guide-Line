import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/main.dart';

/// UI 冒烟测试：装配真实控制器（临时数据目录），验证主要视图能渲染。
void main() {
  late Directory dir;
  late AppController app;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('guideline_ui_');
    app = AppController.bootstrap(dataDirectoryOverride: dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(GuidelineApp(controller: app));
    await tester.pumpAndSettle();
  }

  testWidgets('空数据启动：板块一显示引导，同步状态位显示本地模式', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpApp(tester);

    expect(find.text('项目与灵感'), findsWidgets);
    expect(find.text('还没有项目'), findsOneWidget);
    expect(find.text('灵感箱是空的'), findsOneWidget);
    expect(find.textContaining('本地模式'), findsOneWidget);
  });

  testWidgets('项目树渲染层级与完成状态', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final root = app.ws.createProject(title: '个人知识库', purpose: '让灵感有归宿');
    final child = app.ws.createProject(title: '数据契约', parentId: root.id);
    app.ws.setProjectStatus(child.id, NodeStatus.done);

    await pumpApp(tester);

    expect(find.text('个人知识库'), findsWidgets);
    expect(find.text('数据契约'), findsWidgets);
    expect(find.text('0 个子项目'), findsNothing);
  });

  testWidgets('归档区显示五个分区', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final project = app.ws.createProject(title: '将被归档');
    app.ws.setProjectArchived(project.id, true);

    await pumpApp(tester);
    await tester.tap(find.text('归档区'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已归档（1）'), findsOneWidget);
    expect(find.textContaining('已丢弃（0）'), findsOneWidget);
    expect(find.textContaining('已合并（0）'), findsOneWidget);
    expect(find.textContaining('回收站（0）'), findsOneWidget);
    expect(find.textContaining('本地草稿（0）'), findsOneWidget);
    expect(find.text('取消归档'), findsOneWidget);
  });

  testWidgets('设置页显示数据目录与版本', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpApp(tester);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(find.text('数据目录'), findsOneWidget);
    expect(find.textContaining(dir.path), findsWidgets);
    expect(find.text('1.0.0+1'), findsOneWidget);
    expect(find.text('导出为 .json.gz'), findsOneWidget);
  });

  testWidgets('灵感箱可录入并在列表中显示', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpApp(tester);

    await tester.enterText(find.byType(TextField).first, '随手记一条');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('随手记一条'), findsWidgets);
    expect(app.ws.inspirationInbox.length, 1);
    // 落盘校验：灵感文档已写入磁盘
    expect(File('${dir.path}${Platform.pathSeparator}inspirations.json').existsSync(), isTrue);
  });

  testWidgets('到期视图为空时给出提示', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpApp(tester);
    await tester.tap(find.text('今天 / 本周到期'));
    await tester.pumpAndSettle();

    expect(find.text('没有到期任务'), findsOneWidget);
  });
}
