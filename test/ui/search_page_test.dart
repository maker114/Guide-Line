import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:guideline/app/app_controller.dart';
import 'package:guideline/core/ids.dart';
import 'package:guideline/ui/more/search_page.dart';

import 'scroll_finders.dart';

/// 搜索页的搜索框（实机反馈）：**页面上要有一个明显的框**。
///
/// 原来它是标题栏里一个没有边框的输入框 —— 看着像一行说明文字，
/// 第一眼认不出"这里能打字"。现在是一个带搜索图标、胶囊底色的框。
///
/// Q26：任务命中上还能长按进多选，批量改到期日 / 归档 —— 搜到一条任务
/// 想改期，不必再点进去、在任务线上重新找一遍。
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('guideline_search_test');
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<AppController> boot() async {
    return AppController.bootstrap(dataDirectoryOverride: tempDir);
  }

  testWidgets('搜索框在页面上、带搜索图标与提示词', (tester) async {
    final app = await boot();
    app.run(() => app.ws.createProject(title: '指南线'));

    await tester.pumpWidget(MaterialApp(home: SearchPage(app: app)));
    await tester.pumpAndSettle();

    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('搜索'), findsOneWidget, reason: '标题栏只写标题，输入框挪到页面里');

    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    expect(find.descendant(of: field, matching: find.byIcon(Icons.search)), findsOneWidget);
    expect(find.text('搜项目 / 事件 / 任务 / 灵感'), findsOneWidget);

    // 输入框**不在**标题栏里（那正是原来"看不出来能打字"的原因）
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.byType(TextField)),
      findsNothing,
    );
  });

  testWidgets('打字就有结果，清空按钮能把框清干净', (tester) async {
    final app = await boot();
    app.run(() => app.ws.createProject(title: '指南线'));

    await tester.pumpWidget(MaterialApp(home: SearchPage(app: app)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '指南线');
    await tester.pumpAndSettle();

    expect(find.text('指南线'), findsWidgets);
    expect(find.textContaining('命中 1 条'), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(find.text('输入关键词开始搜索'), findsOneWidget);
  });

  testWidgets('多选任务命中 → 批量设到期日：选中那几条都变了、也落了盘（Q26）', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    final first = app.ws.createTask(eventId: event.id, title: '甲任务');
    final second = app.ws.createTask(eventId: event.id, title: '乙任务');
    app.run(() => app.ws.createProject(title: '任务项目'));

    await tester.pumpWidget(MaterialApp(home: SearchPage(app: app)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '任务');
    await tester.pumpAndSettle();
    expect(find.text('命中 3 条'), findsOneWidget, reason: '两条任务 + 一个项目');

    // 长按一条任务命中 → 进多选
    await tester.longPress(find.text('乙任务'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1 条'), findsOneWidget);

    // 多选里点条目 = 切换选中（这一行由 `AbsorbPointer` 接管，点的是行不是文字）
    await tester.tap(find.text('甲任务'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget);

    await tester.tap(find.byTooltip('设到期日'));
    await tester.pumpAndSettle();
    // 日期面板：点日历里"今天"那一格就落定（选中即生效）
    await tapTodaysDay(tester);
    await tester.pumpAndSettle();

    final today = Ids.todayDate();
    expect(app.ws.findTask(first.id)!.dueAt, today);
    expect(app.ws.findTask(second.id)!.dueAt, today);
    expect(find.text('已选 2 条'), findsNothing, reason: '成功之后退出多选');

    final reloaded = await AppController.bootstrap(dataDirectoryOverride: tempDir);
    expect(reloaded.ws.findTask(first.id)!.dueAt, today);
    expect(reloaded.ws.findTask(second.id)!.dueAt, today);
  });

  testWidgets('「全选」只作用于可见的**任务命中**，项目 / 事件不会被选上（Q26）', (tester) async {
    final app = await boot();
    final event = app.ws.createEvent(name: '一件事');
    app.ws.createTask(eventId: event.id, title: '甲任务');
    app.ws.createTask(eventId: event.id, title: '乙任务');
    app.run(() => app.ws.createProject(title: '任务项目'));

    await tester.pumpWidget(MaterialApp(home: SearchPage(app: app)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '任务');
    await tester.pumpAndSettle();

    // 长按项目命中：多选只收任务，得说明白
    await tester.longPress(find.text('任务项目'));
    await tester.pumpAndSettle();
    expect(find.textContaining('多选只支持任务'), findsOneWidget);
    expect(find.text('已选 1 条'), findsNothing);

    await tester.longPress(find.text('甲任务'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 2 条'), findsOneWidget, reason: '命中 3 条，但只有 2 条任务能选');

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(find.text('已选 0 条'), findsOneWidget);
  });
}
