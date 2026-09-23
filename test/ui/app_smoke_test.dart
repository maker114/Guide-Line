import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/models/enums.dart';
import 'package:guideline/ui/app_shell.dart';

/// 手机端界面冒烟测试：**把四个 Tab 的主干路径真的走一遍**。
///
/// 纯逻辑测试（`test/core/*`）保证规则对，这里保证**接线对**：
/// 用户点得下去的按钮真的能建出数据，并且数据真的落到磁盘上。
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('guideline_ui_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> switchTab(WidgetTester tester, String label) async {
    await tester.tap(
      find.descendant(of: find.byType(NavigationBar), matching: find.text(label)),
    );
    await tester.pumpAndSettle();
  }

  /// 填写并提交 `promptText` 对话框。
  Future<void> submitPrompt(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
  }

  testWidgets('灵感 → 项目 → 事件 → 更多 的主干流程可用，且数据落盘', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    // ---- 1. 速记（默认 Tab）
    expect(find.text('想到什么就先扔进来…'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '把灵感线做成一条链');
    await tester.tap(find.byIcon(Icons.send));
    await tester.pumpAndSettle();
    expect(find.text('把灵感线做成一条链'), findsOneWidget);
    expect(app.ws.inspirationInbox.length, 1);

    // ---- 2. 项目 Tab：建一个根项目
    await switchTab(tester, '项目');
    expect(find.text('还没有项目'), findsOneWidget);
    await tester.tap(find.text('新建项目'));
    await tester.pumpAndSettle();
    await submitPrompt(tester, 'Guide Line');
    expect(find.text('Guide Line'), findsOneWidget);
    expect(app.ws.liveProjects.length, 1);

    // ---- 3. 事件 Tab：建事件 + 主线任务 + 子任务
    await switchTab(tester, '事件');
    expect(find.text('还没有事件'), findsOneWidget);
    await tester.tap(find.text('新建事件'));
    await tester.pumpAndSettle();
    await submitPrompt(tester, '手机端上线');
    expect(find.text('手机端上线'), findsOneWidget);

    // 进任务线
    await tester.tap(find.text('手机端上线'));
    await tester.pumpAndSettle();
    expect(find.text('这条任务线还是空的'), findsOneWidget);

    await tester.tap(find.text('新建主线任务'));
    await tester.pumpAndSettle();
    await submitPrompt(tester, '完成四个 Tab');
    expect(find.text('完成四个 Tab'), findsOneWidget);

    // 点任务行 → 动作面板 → 加一个子任务（验证框内渲染）
    await tester.tap(find.text('完成四个 Tab'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新建子任务'));
    await tester.pumpAndSettle();
    await submitPrompt(tester, '子任务甲');
    expect(find.text('子任务甲'), findsOneWidget);

    // 点状态按钮 = 完成（子任务先完成：父任务有未处理子任务时不允许直接完成）
    expect(find.text('下级 0/1'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.radio_button_unchecked).last);
    await tester.pumpAndSettle();
    expect(app.ws.liveTasks.where((t) => t.status == NodeStatus.done).length, 1);

    await tester.pageBack();
    await tester.pumpAndSettle();

    // ---- 4. 更多 Tab：聚合视图与数据安全页都能打开
    await switchTab(tester, '更多');
    await tester.tap(find.text('全部任务'));
    await tester.pumpAndSettle();
    expect(find.text('完成四个 Tab'), findsOneWidget);
    expect(find.text('子任务甲'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('归档区'));
    await tester.pumpAndSettle();
    expect(find.text('已归档 0'), findsOneWidget);
    expect(find.text('回收站 0'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.text('备份与恢复'));
    await tester.pumpAndSettle();
    expect(find.text('立即备份一份'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // ---- 5. 数据真的在磁盘上（单文件存储）
    final store = File('${tempDir.path}${Platform.pathSeparator}guideline.json');
    expect(store.existsSync(), isTrue, reason: '每次变更都应原子落盘');
    final text = store.readAsStringSync();
    expect(text.contains('把灵感线做成一条链'), isTrue);
    expect(text.contains('Guide Line'), isTrue);
    expect(text.contains('完成四个 Tab'), isTrue);
    expect(text.contains('子任务甲'), isTrue);
    expect(text.contains('"schemaVersion": 2'), isTrue);
  });

  testWidgets('搜索能跨四类实体命中', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    app.run(() => app.ws.createProject(title: '指南线'));
    app.run(() => app.ws.captureInspiration('指南线要速记优先'));
    app.run(() => app.ws.createEvent(name: '指南线发布'));

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await switchTab(tester, '更多');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '指南线');
    await tester.pumpAndSettle();

    // 三条命中各来自一类实体，用"命中字段"区分（标题 / 内容 / 名称）
    expect(find.text('指南线要速记优先'), findsOneWidget);
    expect(find.text('指南线发布'), findsOneWidget);
    expect(find.textContaining('命中「标题」'), findsOneWidget);
    expect(find.textContaining('命中「内容」'), findsOneWidget);
    expect(find.textContaining('命中「名称」'), findsOneWidget);
  });

  testWidgets('归档区能取消归档并让内容回到主视图', (tester) async {
    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final project = app.ws.createProject(title: '会归档的项目');
    app.run(() => app.ws.setProjectArchived(project.id, true));
    expect(app.ws.liveProjects.where((p) => !p.archived).length, 0);

    await tester.pumpWidget(MaterialApp(home: AppShell(app: app)));
    await tester.pumpAndSettle();

    await switchTab(tester, '更多');
    await tester.tap(find.text('归档区'));
    await tester.pumpAndSettle();
    expect(find.text('已归档 1'), findsOneWidget);
    expect(find.text('会归档的项目'), findsOneWidget);

    await tester.tap(find.text('取消归档'));
    await tester.pumpAndSettle();
    expect(app.ws.liveProjects.where((p) => !p.archived).length, 1);
  });

  testWidgets('深色模式 + 1.6 倍字体下四个 Tab 不溢出', (tester) async {
    // 360×780 逻辑像素（常见手机），字体放大到 1.6 倍 —— 布局溢出会直接让测试失败
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final app = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    final project = app.ws.createProject(title: '一个名字相当长的项目名');
    app.run(() => app.ws.updateProject(project.id, purpose: '一句相当长的目的说明，用来撑满一行'));
    final event = app.ws.createEvent(name: '一个名字相当长的事件名');
    final task = app.ws.createTask(eventId: event.id, title: '一条名字相当长的主线任务');
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '子任务',
          parentTaskId: task.id,
          type: TaskType.subtask,
        ));
    app.run(() => app.ws.createTask(
          eventId: event.id,
          title: '并列任务',
          parentTaskId: task.id,
          type: TaskType.parallel,
        ));
    app.run(() => app.ws.captureInspiration('一条比较长的灵感内容，用来检验放大字体后会不会挤爆布局'));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark, useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: AppShell(app: app),
      ),
    );
    await tester.pumpAndSettle();

    await switchTab(tester, '项目');
    await switchTab(tester, '事件');

    // 进任务线并打开任务动作面板（7 项，是最容易溢出的地方）
    await tester.tap(find.text('一个名字相当长的事件名'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('一条名字相当长的主线任务'));
    await tester.pumpAndSettle();
    expect(find.text('新建并列任务'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // 点遮罩关掉面板
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    await switchTab(tester, '更多');
    await tester.tap(find.text('全部任务'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
  });
}
